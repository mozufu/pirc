import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_style_loading.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render_document/src/document_canvas.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_image_cancellation_fixture.dart';

class HeldImageServer {
  HeldImageServer._(this.server) {
    subscription = server.listen((socket) {
      sockets.add(socket);
      final bytes = <int>[];
      String? path;
      void ended() {
        if (path != null &&
            !released.contains(socket) &&
            path!.startsWith('/slow-')) {
          if (!closed.contains(path)) closed.add(path!);
        }
        active.remove(socket);
        sockets.remove(socket);
        socket.destroy();
      }

      socket.listen(
        (data) {
          if (path != null) return;
          bytes.addAll(data);
          final header = latin1.decode(bytes);
          if (!header.contains('\r\n\r\n')) return;
          final lines = header.split('\r\n');
          final target = lines.first.split(' ')[1];
          path = Uri.parse(target).path;
          final headers = <String, String>{};
          for (final line in lines.skip(1)) {
            final colon = line.indexOf(':');
            if (colon > 0) {
              headers[line.substring(0, colon).toLowerCase()] = line
                  .substring(colon + 1)
                  .trim();
            }
          }
          requests.add({
            'path': path,
            'target': target,
            'referer': headers['referer'],
            'origin': headers['origin'],
          });
          if (path!.startsWith('/slow-')) {
            active[socket] = path!;
          } else if (path == '/image-ok.png') {
            unawaited(writePng(socket));
          } else {
            unexpected.add(path!);
            socket.write(
              'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
            );
            unawaited(socket.flush().then((_) => socket.close()));
          }
        },
        onDone: ended,
        onError: (Object error) {
          errors.add('$error');
          ended();
        },
      );
    });
  }
  static Future<HeldImageServer> start() async => HeldImageServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  );
  final ServerSocket server;
  late final StreamSubscription<Socket> subscription;
  final sockets = <Socket>{}, released = <Socket>{};
  final active = <Socket, String>{};
  final requests = <Json>[];
  final closed = <String>[], unexpected = <String>[], errors = <String>[];
  final png = base64Decode(documentImageCancellationPngBase64);
  String get origin => 'http://127.0.0.1:${server.port}';
  int count(String path) => requests.where((r) => r['path'] == path).length;
  Future<void> writePng(Socket socket) async {
    released.add(socket);
    socket.write(
      'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: ${png.length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n',
    );
    socket.add(png);
    await socket.flush();
    await socket.close();
  }

  Future<void> release(String path) async {
    final selected = active.entries
        .where((e) => e.value == path)
        .map((e) => e.key)
        .toList();
    expect(
      selected,
      hasLength(1),
      reason: 'one live request must remain for $path',
    );
    await writePng(selected.single);
  }

  Future<void> dispose() async {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await subscription.cancel();
    await server.close();
  }
}

Json imageProbe(NativeFetchedDocument document) {
  final text =
      html
          .parse(document.scripts?.content?.text ?? '')
          .querySelector('#result')
          ?.text ??
      '';
  return text.startsWith('{') ? obj(jsonDecode(text)) : {};
}

Future<void> until(
  WidgetTester t,
  bool Function() predicate,
  String reason,
) async {
  final clock = Stopwatch()..start();
  for (
    var i = 0;
    i < 500 && !predicate() && clock.elapsed < const Duration(seconds: 8);
    i++
  ) {
    await t.pump(const Duration(milliseconds: 10));
  }
  expect(predicate(), true, reason: reason);
}

Future<void> press(WidgetTester t, String label) async {
  final button = find.byWidgetPredicate(
    (w) => w is NativeHtmlButtonWidget && w.button.label == label,
  );
  await until(t, () => button.evaluate().isNotEmpty, 'render button $label');
  await t.ensureVisible(button);
  await t.pump();
  await t.tap(button);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native image replacement cancels HTTP, preserves independent loads and paints current bitmap',
    (t) async {
      final theme = await PircTheme.load();
      final gateway = Gateway();
      try {
        for (final width in [390.0, 860.0]) {
          for (final brightness in [Brightness.light, Brightness.dark]) {
            for (final scale in [1.0, 2.0]) {
              t.view.physicalSize = Size(width, 900);
              t.view.devicePixelRatio = 1;
              final server = await HeldImageServer.start();
              final bytes = Uint8List.fromList(
                utf8.encode(documentImageCancellationFixture),
              );
              final document = NativeFetchedDocument(
                id: 1,
                url: '${server.origin}/fixture',
                status: 200,
                bytes: bytes,
                mimeType: 'text/html',
                headers: {},
                content: NativeHtmlDocumentContent.fromBytes(
                  bytes,
                  mimeType: 'text/html',
                  charset: 'utf-8',
                ),
              );
              final styles =
                  await NativeDocumentStyleLoader(
                    isCurrent: () => true,
                    fetch: (_, _) async => throw StateError('no external CSS'),
                    resolve: (_, _) async =>
                        throw StateError('no external CSS'),
                  ).load(
                    document.content.text,
                    baseUrl: document.url,
                    documentEncoding: document.content.encoding,
                  );
              document.stylesheets = styles.stylesheets;
              expect(styles.diagnostics, isEmpty);
              final boundaryKey = GlobalKey();
              Json part(String name) => obj(imageProbe(document)[name]);
              try {
                await t.pumpWidget(
                  MaterialApp(
                    theme: theme.build(brightness),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: Scaffold(
                      body: RepaintBoundary(
                        key: boundaryKey,
                        child: NativeFetchedDocumentView(
                          document: document,
                          gateway: gateway,
                          onLink: (_) {},
                          onSubmit: (_) {},
                        ),
                      ),
                    ),
                  ),
                );
                await until(
                  t,
                  () =>
                      document.scripts?.ready == true &&
                      imageProbe(document).containsKey('replacement'),
                  'script handlers must finish initialising before the first tap',
                );
                await press(t, '開始單張替換');
                await until(
                  t,
                  () => server.count('/slow-image-replace.png') == 1,
                  'old image HTTP reaches server',
                );
                final replacementClock = Stopwatch()..start();
                await press(t, '改用新圖片');
                await until(
                  t,
                  () =>
                      server.closed.contains('/slow-image-replace.png') &&
                      part('replacement')['newLoad'] == true &&
                      part('replacement')['newDecode'] == 'resolved',
                  'replacement must cancel old TCP and decode new image',
                );
                replacementClock.stop();
                expect(
                  replacementClock.elapsed,
                  lessThan(const Duration(seconds: 10)),
                );
                expect(
                  part('replacement')['oldDecode'],
                  'rejected:EncodingError',
                );
                expect(part('replacement')['newError'], 0);
                expect(part('replacement')['staleLoads'], 0);
                expect(part('replacement')['naturalWidth'], 2);
                expect(part('replacement')['naturalHeight'], 2);

                await press(t, '開始六張慢圖片');
                await until(
                  t,
                  () => List.generate(
                    6,
                    (i) => server.count('/slow-image-$i.png'),
                  ).every((c) => c == 1),
                  'six image sockets must be active before cancel',
                );
                final sixClock = Stopwatch()..start();
                await press(t, '取消六張慢圖片');
                await press(t, '載入第七張圖片');
                await until(
                  t,
                  () =>
                      List.generate(
                        6,
                        (i) => server.closed.contains('/slow-image-$i.png'),
                      ).every((c) => c) &&
                      part('six')['loaded'] == 6 &&
                      part('seventh')['loaded'] == true,
                  'all six canceled TCP connections must free replacement and seventh loads',
                );
                sixClock.stop();
                expect(sixClock.elapsed, lessThan(const Duration(seconds: 10)));
                expect(part('six')['oldDecodeRejected'], 6);
                expect(part('six')['errorCount'], 0);
                expect(part('seventh')['error'], '');
                expect(part('canvas')['drawn'], true);

                await press(t, '開始兩個消費者');
                await until(
                  t,
                  () =>
                      server.count('/slow-image-owner.png') == 1 &&
                      server.count('/slow-image-other.png') == 1,
                  'both independent consumers must have active HTTP',
                );
                await press(t, '更新第一個消費者');
                await until(
                  t,
                  () =>
                      server.closed.contains('/slow-image-owner.png') &&
                      part('consumer')['ownerLoaded'] == true &&
                      part('consumer')['ownerNewDecode'] == 'resolved',
                  'only replaced image must cancel and reload',
                );
                expect(server.closed.contains('/slow-image-other.png'), false);
                expect(part('consumer')['otherLoaded'], false);
                await server.release('/slow-image-other.png');
                await until(
                  t,
                  () => part('consumer')['otherLoaded'] == true,
                  'unrelated image must remain loadable',
                );
                expect(
                  part('consumer')['ownerOldDecode'],
                  'rejected:EncodingError',
                );
                expect(part('consumer')['otherError'], '');

                await press(t, '開始策略圖片');
                await until(
                  t,
                  () => server.count('/slow-image-policy.png') == 1,
                  'initial policy request starts',
                );
                await press(t, '更新referrerPolicy');
                await until(
                  t,
                  () => part('policy')['updated'] == true,
                  'policy reflection updates',
                );
                await t.pump(const Duration(milliseconds: 150));
                expect(server.count('/slow-image-policy.png'), 1);
                expect(server.closed.contains('/slow-image-policy.png'), false);
                await press(t, '載入策略更新後的新來源');
                await until(
                  t,
                  () =>
                      server.closed.contains('/slow-image-policy.png') &&
                      server.count('/slow-image-policy-next.png') == 1,
                  'different source uses updated policy and cancels previous HTTP',
                );
                expect(
                  server.requests.singleWhere(
                    (r) => r['path'] == '/slow-image-policy-next.png',
                  )['referer'],
                  isNull,
                );
                await server.release('/slow-image-policy-next.png');
                await until(
                  t,
                  () => part('policy')['nextCurrentSrc'].toString().contains(
                    '/slow-image-policy-next.png',
                  ),
                  'new policy image loads',
                );
                expect(part('policy')['nextError'], '');

                await press(t, '開始同來源圖片');
                await until(
                  t,
                  () => server.count('/slow-image-same.png') == 1,
                  'same-source initial request starts',
                );
                await press(t, '重設相同src');
                await until(
                  t,
                  () => part('sameSrc')['reset'] == true,
                  'same-source setter runs',
                );
                await t.pump(const Duration(milliseconds: 150));
                expect(server.count('/slow-image-same.png'), 1);
                expect(server.closed.contains('/slow-image-same.png'), false);
                await server.release('/slow-image-same.png');
                await until(
                  t,
                  () =>
                      part('sameSrc')['loaded'] == true &&
                      part('sameSrc')['decode'] == 'resolved',
                  'same pending URL must preserve its original decode promise',
                );
                expect(part('sameSrc')['naturalWidth'], 2);
                expect(part('sameSrc')['naturalHeight'], 2);

                final canvas = find.byType(NativeDocumentCanvas);
                expect(canvas, findsOneWidget);
                await t.ensureVisible(canvas);
                await t.pump();
                expect(t.getSize(canvas), const Size(8, 8));
                final boundary = t.renderObject<RenderRepaintBoundary>(
                  find.byKey(boundaryKey),
                );
                final bitmap = await boundary.toImage(pixelRatio: 1);
                final samples = <String, List<int>>{};
                try {
                  final data = (await bitmap.toByteData(
                    format: ui.ImageByteFormat.rawStraightRgba,
                  ))!;
                  final rgba = data.buffer.asUint8List(
                    data.offsetInBytes,
                    data.lengthInBytes,
                  );
                  final offset =
                      t.getTopLeft(canvas) -
                      t.getTopLeft(find.byKey(boundaryKey));
                  for (final p in [
                    (1, 1, <int>[17, 34, 51, 255]),
                    (4, 4, <int>[37, 181, 92, 255]),
                  ]) {
                    final index =
                        (((offset.dy + p.$2 + .5).floor()) * bitmap.width +
                            (offset.dx + p.$1 + .5).floor()) *
                        4;
                    final sample = rgba.sublist(index, index + 4);
                    samples['${p.$1},${p.$2}'] = sample;
                    expect(sample, p.$3);
                  }
                } finally {
                  bitmap.dispose();
                }
                expect(server.unexpected, isEmpty);
                expect(document.scripts!.ready, true);
                expect(document.scripts!.diagnostics, isEmpty);
                expect(t.takeException(), isNull);
                debugPrint(
                  'NATIVE_IMAGE_CANCEL ${jsonEncode({'width': width, 'theme': brightness.name, 'textScale': scale, 'result': imageProbe(document), 'requests': server.requests, 'canceled': server.closed, 'pixels': samples, 'replacementMs': replacementClock.elapsedMilliseconds, 'sixMs': sixClock.elapsedMilliseconds})}',
                );
              } finally {
                final scripts = document.scripts;
                await t.pumpWidget(const SizedBox());
                document.dispose();
                await scripts?.closed;
                await t.pump();
                await server.dispose();
              }
            }
          }
        }
      } finally {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      }
    },
  );
}
