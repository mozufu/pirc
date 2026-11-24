import 'package:pirc_mobile/live/render_host_adapter.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_background_image.dart';
import 'package:pirc_render/src/html_background_layers.dart';
import 'live_test.dart' show FakeGateway;
import 'svg_background_lifecycle_test.dart' show host, color;
import 'document_background_image_test.dart' show firstImage;

void main() {
  testWidgets(
    'SVG source cache evicts old entries after its bounded capacity',
    (t) async {
      final cache = NativeSvgBackgroundCache(), owner = Object();
      final gateway = FakeGateway();
      gateway.handler = (_, _) async => {
        'bytes': utf8.encode(
          '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>',
        ),
        'mimeType': 'image/svg+xml',
      };
      NativeDocumentBackgroundImage provider(int index) =>
          NativeDocumentBackgroundImage(
            source: Uri.parse('tile-$index.svg'),
            accountIdentity: 'a',
            owner: owner,
            fetcher: gatewayImageFetcher(gateway),
            svgCache: cache,
            isCurrent: () => true,
          );
      for (var i = 0; i < 65; i++) {
        await expectLater(
          firstImage(provider(i)),
          throwsA(isA<NativeDocumentSvgBackground>()),
        );
      }
      await expectLater(
        firstImage(provider(64)),
        throwsA(isA<NativeDocumentSvgBackground>()),
      );
      expect(gateway.calls.where((c) => c.$1 == 'image'), hasLength(65));
      await expectLater(
        firstImage(provider(0)),
        throwsA(isA<NativeDocumentSvgBackground>()),
      );
      expect(gateway.calls.where((c) => c.$1 == 'image'), hasLength(66));
      cache.clear();
      await gateway.stream.close();
    },
  );
  testWidgets('late SVG response cannot repopulate a replaced HTML source', (
    t,
  ) async {
    final cache = NativeSvgBackgroundCache(), owner = Object();
    final gateway = FakeGateway();
    final pending = Completer<dynamic>();
    var reads = 0;
    final response = {
      'bytes': utf8.encode(
        '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>',
      ),
      'mimeType': 'image/svg+xml',
    };
    gateway.handler = (_, _) =>
        ++reads == 1 ? pending.future : Future.value(response);
    NativeDocumentBackgroundImage provider() => NativeDocumentBackgroundImage(
      source: Uri.parse('same.svg'),
      accountIdentity: 'a',
      owner: owner,
      fetcher: gatewayImageFetcher(gateway),
      svgCache: cache,
      isCurrent: () => true,
    );
    final old = expectLater(
      firstImage(provider()),
      throwsA(isA<NativeDocumentSvgBackground>()),
    );
    await t.pump();
    cache.clear();
    pending.complete(response);
    await old;
    await expectLater(
      firstImage(provider()),
      throwsA(isA<NativeDocumentSvgBackground>()),
    );
    expect(reads, 2, reason: 'the new source must fetch its own response');
    await expectLater(
      firstImage(provider()),
      throwsA(isA<NativeDocumentSvgBackground>()),
    );
    expect(reads, 2);
    cache.clear();
    await gateway.stream.close();
  });

  testWidgets('equal layer rebuilds retain SVG, while account changes reload it', (
    t,
  ) async {
    var account = 'a';
    final owner = Object();
    final cache = NativeSvgBackgroundCache();
    var rebuild = 0;
    Widget rebuilt(Decoration decoration) => KeyedSubtree(
      key: ValueKey(++rebuild),
      child: host(decoration, 100, 50),
    );
    final gateway = FakeGateway();
    gateway.handler = (_, _) async => {
      'bytes': utf8.encode(
        '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20"><rect width="40" height="20" fill="${account == 'a' ? 'red' : 'blue'}"/></svg>',
      ),
      'mimeType': 'image/svg+xml',
    };
    NativeHtmlLayeredBackgroundDecoration decoration() {
      final scope = account;
      return NativeHtmlLayeredBackgroundDecoration(
        const BoxDecoration(color: Color(0xffffffff)),
        nativeHtmlBackgroundLayers(const [
          MapEntry(
            'background-image',
            'linear-gradient(transparent,transparent), url(relative.svg)',
          ),
          MapEntry('background-repeat', 'no-repeat'),
        ]),
        [
          null,
          NativeDocumentBackgroundImage(
            source: Uri.parse('relative.svg'),
            fetcher: gatewayImageFetcher(gateway),
            baseUrl: 'https://gateway.example/docs/',
            svgCache: cache,
            accountIdentity: scope,
            owner: owner,
            isCurrent: () => account == scope,
          ),
        ],
      );
    }

    await t.pumpWidget(rebuilt(decoration()));
    await color(t, 5, 5, [255, 0, 0, 255]);
    for (var i = 0; i < 3; i++) {
      // Reparse CSS and create fresh provider/decorations as a document rebuild
      // does. The decoded vector must remain visible without a new request.
      await t.pumpWidget(rebuilt(decoration()));
      await color(t, 5, 5, [255, 0, 0, 255]);
      expect(gateway.calls.where((c) => c.$1 == 'image'), hasLength(1));
    }
    account = 'b';
    await t.pumpWidget(rebuilt(decoration()));
    await color(t, 5, 5, [0, 0, 255, 255]);
    expect(gateway.calls.where((c) => c.$1 == 'image'), hasLength(2));
    cache.clear();
    await t.pumpWidget(rebuilt(decoration()));
    await color(t, 5, 5, [0, 0, 255, 255]);
    expect(
      gateway.calls.where((c) => c.$1 == 'image'),
      hasLength(3),
      reason: 'replacing the HTML source clears its resource generation',
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await gateway.stream.close();
  });
}
