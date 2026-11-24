import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

import 'document_formdata_fixture.dart';

class _PickedGateway extends Gateway {
  int picks = 0;

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'pickAttachments') {
      picks++;
      return [
        {
          'name': 'selected-資料.bin',
          'mimeType': 'application/octet-stream',
          'bytes': Uint8List.fromList(const [0, 127, 128, 255, 13, 10]),
        },
      ];
    }
    return super.call(method, args);
  }
}

class _CapturedSubmission {
  const _CapturedSubmission(this.submission, this.request, this.targetWindow);

  final NativeHtmlFormSubmission submission;
  final NativeHtmlFormRequest request;
  final NativeDocumentWindow targetWindow;
}

String _instrumentFormdataHtml(String source) {
  const appendix = r'''
  <form id="generated-file-form" action="/generated-file" method="post"
        enctype="multipart/form-data" target="generated-file-frame">
    <input name="marker" value="programmatic">
    <button id="generated-file-submit" type="submit">Submit generated file</button>
  </form>
  <iframe name="generated-file-frame"></iframe>
  <script>
    const generatedFileForm = document.querySelector('#generated-file-form');
    generatedFileForm.addEventListener('formdata', event => {
      const bytes = new Uint8Array(1024 * 1024);
      for (let index = 0; index < bytes.length; index++) bytes[index] = index & 255;
      const file = new File([bytes], 'generated-1MiB.bin', {
        type: 'application/octet-stream',
        lastModified: 123456789
      });
      window.__generatedFileMetadata = {
        name: file.name,
        type: file.type,
        lastModified: file.lastModified,
        size: file.size
      };
      event.formData.append('generated', file);
    });
  </script>
  <pre id="native-formdata-snapshot">WAITING</pre>
  <script>
    (() => {
      const oracle = window.__formDataOracle;
      const snapshot = document.querySelector('#native-formdata-snapshot');
      const formFlags = () => {
        const property = oracle.events.find(event =>
          event.type === 'formdata-property' && event.form === 'button-form'
        );
        const documentEvent = oracle.events.find(event =>
          event.type === 'formdata-document' && event.form === 'button-form'
        );
        if (!property || !documentEvent) return null;
        return {
          bubbles: property.flags.bubbles,
          cancelable: property.flags.cancelable,
          composed: property.flags.composed,
          isTrusted: property.flags.isTrusted,
          defaultPrevented: property.flags.defaultPrevented,
          formEventPhase: property.flags.eventPhase,
          documentEventPhase: documentEvent.flags.eventPhase,
          targetIsForm: property.flags.targetIsForm
        };
      };
      const attributeMutations = () => {
        const button = document.querySelector('#button-form');
        const request = document.querySelector('#request-form');
        return {
          button: {
            actionPath: new URL(button.action).pathname,
            method: button.method,
            enctype: button.enctype,
            target: button.target
          },
          request: {
            actionPath: new URL(request.action).pathname,
            method: request.method,
            enctype: request.enctype,
            target: request.target
          }
        };
      };
      const refresh = () => {
        snapshot.textContent = JSON.stringify({
          counts: oracle.counts,
          events: oracle.events,
          reentry: oracle.reentry,
          cancel: {
            defaultPrevented: oracle.cancel.defaultPrevented
          },
          nativeEventFlags: formFlags(),
          buttonEventOrder: oracle.events
            .filter(event => event.form === 'button-form')
            .map(event => event.type),
          attributeMutations: attributeMutations(),
          propertyCases: window.__propertyCases,
          generatedFileMetadata: window.__generatedFileMetadata ?? null
        });
      };
      document.addEventListener('submit', refresh);
      document.addEventListener('formdata', refresh);
      refresh();
    })();
  </script>
''';
  if (!source.contains('</body>')) {
    throw StateError('Shared formdata fixture has no body end tag.');
  }
  return source.replaceFirst('</body>', '$appendix</body>');
}

List<Json> _decodeMultipartRequest(List<int> body, String contentType) {
  final boundary = RegExp(
    r'boundary=(?:"([^"]+)"|([^;\s]+))',
  ).firstMatch(contentType);
  if (boundary == null) throw StateError('Multipart boundary is missing.');
  final marker = '--${boundary[1] ?? boundary[2]!}';
  final result = <Json>[];
  for (var part in latin1.decode(body).split(marker).skip(1)) {
    if (part.startsWith('--')) break;
    if (!part.startsWith('\r\n') || !part.endsWith('\r\n')) {
      throw StateError('Multipart framing is invalid.');
    }
    part = part.substring(2, part.length - 2);
    final headerEnd = part.indexOf('\r\n\r\n');
    if (headerEnd < 0) throw StateError('Multipart headers are missing.');
    final headers = utf8.decode(latin1.encode(part.substring(0, headerEnd)));
    final bytes = latin1.encode(part.substring(headerEnd + 4));
    final disposition = RegExp(
      r'Content-Disposition:\s*form-data;([^\r\n]+)',
      caseSensitive: false,
    ).firstMatch(headers)?[1];
    if (disposition == null) {
      throw StateError('Multipart disposition is missing.');
    }
    String? parameter(String key) => RegExp(
      r'(?:^|;)\s*' + key + r'="([^"]*)"',
      caseSensitive: false,
    ).firstMatch(disposition)?[1];
    final name = parameter('name');
    final filename = parameter('filename');
    if (name == null) throw StateError('Multipart name is missing.');
    if (filename == null) {
      result.add({'name': name, 'kind': 'text', 'value': utf8.decode(bytes)});
    } else {
      result.add({
        'name': name,
        'kind': 'file',
        'filename': filename,
        'mimeType': RegExp(
          r'Content-Type:\s*([^\r\n]+)',
          caseSensitive: false,
        ).firstMatch(headers)?[1],
        'size': bytes.length,
        'base64': base64Encode(bytes),
      });
    }
  }
  return result;
}

List<Json> _decodeQueryEntries(String query) {
  if (query.isEmpty) return [];
  return [
    for (final pair in query.split('&'))
      if (pair.isNotEmpty)
        () {
          final separator = pair.indexOf('=');
          final rawName = separator < 0 ? pair : pair.substring(0, separator);
          final rawValue = separator < 0 ? '' : pair.substring(separator + 1);
          return <String, dynamic>{
            'name': Uri.decodeQueryComponent(rawName),
            'kind': 'text',
            'value': Uri.decodeQueryComponent(rawValue),
          };
        }(),
  ];
}

List<Json> _decodeRequestEntries(NativeHtmlFormRequest request) {
  if (request.method == 'GET') {
    final query = Uri.parse(request.url).query;
    return _decodeQueryEntries(query);
  }
  final bytes = request.bodyBytes;
  if (bytes == null) throw StateError('POST form has no binary body.');
  final contentType = request.contentType ?? '';
  if (!contentType.toLowerCase().startsWith('multipart/form-data')) {
    throw StateError('Expected a multipart POST, got $contentType');
  }
  return _decodeMultipartRequest(bytes, contentType);
}

Map<String, dynamic> _readSnapshot(NativeFetchedDocument document) {
  final markup = document.scripts?.content?.text;
  if (markup == null) {
    throw StateError('Native document script snapshot is absent.');
  }
  final snapshotText = html
      .parse(markup)
      .querySelector('#native-formdata-snapshot')
      ?.text
      .trim();
  if (snapshotText == null ||
      snapshotText.isEmpty ||
      snapshotText == 'WAITING') {
    throw StateError('Native formdata event snapshot has not been published.');
  }
  return Map<String, dynamic>.from(jsonDecode(snapshotText) as Map);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native FormData submission matches shared Chrome event and wire oracle',
    (tester) async {
      final expected = Map<String, dynamic>.from(
        jsonDecode(formDataExpectedOracleJson) as Map,
      );
      final theme = await PircTheme.load();
      final fixtureHtml = _instrumentFormdataHtml(formDataHtml);

      Future<void> until(
        bool Function() condition,
        String label,
        NativeFetchedDocument document,
      ) async {
        for (var index = 0; index < 240 && !condition(); index++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(
          condition(),
          isTrue,
          reason: '$label: ${document.scripts?.diagnostics.toString() ?? ''}',
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: label);
      }

      Finder button(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget && widget.button.label == label,
      );

      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pump();
        expect(target.hitTestable(), findsOneWidget);
        await tester.tap(target);
      }

      final receipts = <Json>[];
      final failures = <Object>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final token = 'pirc_dev_${List.filled(43, 'A').join()}';
      // Only this loopback pairing verifier is synthetic. The saved credential,
      // account principal, native document transport and HTTP body are real.
      final listener = server.listen((request) async {
        try {
          if (request.headers.value('authorization') != 'Bearer $token') {
            throw StateError('Missing local fixture device bearer.');
          }
          if (request.method == 'GET' && request.uri.path == '/api/sessions') {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"sessions":[]}');
            await request.response.close();
            return;
          }
          final body = BytesBuilder();
          await for (final chunk in request) {
            body.add(chunk);
          }
          final bytes = body.takeBytes();
          final contentType = request.headers.value('content-type');
          final entries = request.method == 'GET'
              ? _decodeQueryEntries(request.uri.query)
              : _decodeMultipartRequest(bytes, contentType ?? '');
          receipts.add({
            'method': request.method,
            'path': request.uri.path,
            'search': request.uri.hasQuery ? '?${request.uri.query}' : '',
            'contentType': contentType?.split(';').first,
            'entries': entries,
          });
          request.response.headers.contentType = ContentType.html;
          request.response.headers.set('cache-control', 'no-store');
          request.response.write(
            '<p>DONE:${request.method}:${request.uri.path}</p>',
          );
          await request.response.close();
        } catch (error) {
          failures.add(error);
          request.response.statusCode = 500;
          await request.response.close();
        }
      });
      final pairingGateway = Gateway();
      var matrixIndex = 0;
      try {
        await pairingGateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': origin, 'token': token},
          ).toString(),
        });
        for (final width in [390.0, 860.0]) {
          for (final brightness in Brightness.values) {
            for (final scale in [1.0, 2.0]) {
              final gateway = _PickedGateway();
              final windows = NativeDocumentWindows(gateway);
              final sourceUrl = '$origin/formdata-fixture';
              final sourceWindow = windows.target(
                '',
                null,
                sourceUrl: sourceUrl,
              );
              final sourceBytes = Uint8List.fromList(utf8.encode(fixtureHtml));
              final document = NativeFetchedDocument(
                id: matrixIndex + 1,
                url: sourceUrl,
                status: 200,
                bytes: sourceBytes,
                mimeType: 'text/html',
                headers: {},
                content: NativeHtmlDocumentContent.fromBytes(
                  sourceBytes,
                  mimeType: 'text/html',
                  charset: 'utf-8',
                ),
              );
              sourceWindow.history.add(
                NativeDocumentHistoryItem(sourceUrl, document),
              );
              sourceWindow.index = 0;
              windows.select(sourceWindow);
              final captures = <_CapturedSubmission>[];

              void onSubmit(NativeHtmlFormSubmission submission) {
                final request = submission.buildRequest(documentUrl: sourceUrl);
                final targetName =
                    request.targetSpecified || request.target.isNotEmpty
                    ? request.target
                    : document.content.baseTarget ?? '';
                final targetWindow = windows.target(
                  targetName,
                  sourceWindow,
                  sourceUrl: sourceUrl,
                );
                captures.add(
                  _CapturedSubmission(submission, request, targetWindow),
                );
                unawaited(
                  targetWindow
                      .load(request, baseUrl: sourceUrl)
                      .then((result) {
                        if (result != NativeDocumentLoadResult.committed) {
                          failures.add(
                            StateError(
                              'Native navigation: $result ${targetWindow.error}',
                            ),
                          );
                        }
                      })
                      .catchError((Object error) {
                        failures.add(error);
                      }),
                );
              }

              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);
              try {
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
                      child: Scaffold(
                        body: NativeDocumentScope(
                          windows: windows,
                          window: sourceWindow,
                          documentUrl: sourceUrl,
                          child: NativeFetchedDocumentView(
                            key: ValueKey('formdata-$matrixIndex'),
                            document: document,
                            gateway: gateway,
                            onLink: (_) {},
                            onSubmit: onSubmit,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                await until(
                  () => document.scripts?.ready == true,
                  'Native JavaScript runtime ready',
                  document,
                );
                await until(
                  () =>
                      document.scripts?.content?.text.contains(
                        'native-formdata-snapshot',
                      ) ==
                      true,
                  'Initial event snapshot',
                  document,
                );

                await tap(find.byType(NativeHtmlFileInputWidget));
                await until(
                  () => gateway.picks == 1,
                  'Synthetic picker boundary',
                  document,
                );

                await tester.pumpAndSettle();
                Future<void> verifySubmission(String key) async {
                  final spec = Map<String, dynamic>.from(expected[key] as Map);
                  final priorCount = captures.length;
                  final priorReceipts = receipts.length;
                  final label = switch (key) {
                    'buttonSubmit' => 'Submit button',
                    'requestSubmit' => 'Run requestSubmit',
                    'directSubmit' => 'Run form.submit()',
                    'reentry' => 'Run reentry requestSubmit',
                    'cancel' => 'Run cancelled requestSubmit',
                    'generatedFile' => 'Submit generated file',
                    _ => throw StateError('Unknown fixture submission $key'),
                  };
                  await tap(button(label));
                  if (key != 'cancel') {
                    await until(
                      () => captures.length == priorCount + 1,
                      '$key native request capture',
                      document,
                    );
                    final captured = captures.last;
                    final request = captured.request;
                    final uri = Uri.parse(sourceUrl).resolve(request.url);
                    expect(request.method, spec['method'], reason: key);
                    expect(uri.path, spec['path'], reason: key);
                    expect(
                      uri.hasQuery ? '?${uri.query}' : '',
                      spec['search'],
                      reason: key,
                    );
                    expect(
                      request.contentType?.split(';').first,
                      spec['contentType'],
                      reason: key,
                    );
                    expect(request.target, spec['targetFrame'], reason: key);
                    expect(
                      captured.targetWindow.name,
                      spec['targetFrame'],
                      reason: key,
                    );
                    expect(
                      _decodeRequestEntries(request),
                      spec['entries'],
                      reason: '$key ordered request entries',
                    );
                    await until(
                      () =>
                          receipts.length == priorReceipts + 1 &&
                          captured.targetWindow.current?.document != null &&
                          !captured.targetWindow.loading,
                      '$key real native HTTP navigation failures=$failures',
                      document,
                    );
                    expect(failures, isEmpty);
                    expect(receipts.last, {
                      for (final field in [
                        'method',
                        'path',
                        'search',
                        'contentType',
                        'entries',
                      ])
                        field: spec[field],
                    });
                    expect(
                      captured.targetWindow.current!.document!.content.text,
                      contains('DONE:${spec['method']}:${spec['path']}'),
                    );
                    if (key == 'generatedFile') {
                      final generated = _decodeRequestEntries(
                        request,
                      ).singleWhere((entry) => entry['name'] == 'generated');
                      expect(generated['filename'], 'generated-1MiB.bin');
                      expect(generated['mimeType'], 'application/octet-stream');
                      expect(generated['size'], 1024 * 1024);
                      final bytes = base64Decode(generated['base64'] as String);
                      for (var index = 0; index < bytes.length; index++) {
                        if (bytes[index] != index % 256) {
                          fail('Generated file byte differs at offset $index');
                        }
                      }
                    }
                  } else {
                    await until(
                      () {
                        try {
                          return ((_readSnapshot(document)['counts']
                                      as Map)['cancel-form']
                                  as Map)['submit'] ==
                              1;
                        } catch (_) {
                          return false;
                        }
                      },
                      'Cancelled submit event',
                      document,
                    );
                    await tester.pump(const Duration(milliseconds: 200));
                    expect(
                      captures.length,
                      priorCount,
                      reason: 'cancelled submit',
                    );
                    expect(
                      receipts.length,
                      priorReceipts,
                      reason: 'cancelled HTTP',
                    );
                  }
                }

                for (final key in [
                  'buttonSubmit',
                  'requestSubmit',
                  'directSubmit',
                  'reentry',
                  'cancel',
                ]) {
                  await verifySubmission(key);
                }

                final state = _readSnapshot(document);
                expect(state['counts'], expected['submissionCounts']);
                expect(state['nativeEventFlags'], expected['nativeEventFlags']);
                expect(state['buttonEventOrder'], expected['buttonEventOrder']);
                expect(
                  state['attributeMutations'],
                  expected['attributeMutations'],
                );
                expect(state['propertyCases'], expected['propertyCases']);
                expect(
                  (state['reentry'] as Map)['nested'],
                  (expected['reentry'] as Map)['nested'],
                );
                expect((state['cancel'] as Map)['defaultPrevented'], true);

                if (matrixIndex == 0) {
                  final generatedSpec = <String, dynamic>{
                    'method': 'POST',
                    'path': '/generated-file',
                    'search': '',
                    'contentType': 'multipart/form-data',
                    'targetFrame': 'generated-file-frame',
                    'entries': [
                      {
                        'name': 'marker',
                        'kind': 'text',
                        'value': 'programmatic',
                      },
                      {
                        'name': 'generated',
                        'kind': 'file',
                        'filename': 'generated-1MiB.bin',
                        'mimeType': 'application/octet-stream',
                        'size': 1024 * 1024,
                        'base64': base64Encode(
                          List<int>.generate(
                            1024 * 1024,
                            (index) => index % 256,
                          ),
                        ),
                      },
                    ],
                  };
                  expected['generatedFile'] = generatedSpec;
                  await verifySubmission('generatedFile');
                  final stateAfterGeneratedFile = _readSnapshot(document);
                  expect(stateAfterGeneratedFile['generatedFileMetadata'], {
                    'name': 'generated-1MiB.bin',
                    'type': 'application/octet-stream',
                    'lastModified': 123456789,
                    'size': 1024 * 1024,
                  });
                  debugPrint(
                    'FORMDATA:generated-programmatic-1MiB:verified-real-HTTP',
                  );
                }

                expect(failures, isEmpty);
                expect(gateway.picks, 1);
                final targetNames = captures
                    .map((capture) => capture.targetWindow.name)
                    .toSet();
                expect(
                  targetNames,
                  containsAll([
                    'button-before-frame',
                    'request-before-frame',
                    'direct-frame',
                    'reentry-frame',
                  ]),
                );
                expect(targetNames, isNot(contains('cancel-frame')));
                debugPrint(
                  'FORMDATA:chrome-wire-and-event-real-HTTP-match:$width:${brightness.name}:$scale',
                );
              } finally {
                await tester.pumpWidget(const SizedBox.shrink());
                final closed = document.scripts?.closed;
                windows.dispose();
                await closed;
                tester.view.reset();
              }
              matrixIndex++;
            }
          }
        }
      } finally {
        await pairingGateway.call('unpair');
        await listener.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
