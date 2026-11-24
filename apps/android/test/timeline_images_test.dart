import 'package:pirc_mobile/rendering/remote_content_gate.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/timeline_attachment_image.dart';
import 'package:pirc_mobile/live/timeline_tools.dart';
import 'live_test.dart' show FakeGateway, theme;

void expectImageSize(Size actual, Size expected) {
  expect(actual.width, closeTo(expected.width, 0.0001));
  expect(actual.height, closeTo(expected.height, 0.0001));
}

final timelineImageFixture = obj(
  jsonDecode(
    File('../../fixtures/mobile-parity/timeline-image.json').readAsStringSync(),
  ),
);
Json timelineSvg(String kind) => {
  'bytes': Uint8List.fromList(
    utf8.encode('${obj(timelineImageFixture['assets'])[kind]}'),
  ),
  'mimeType': 'image/svg+xml',
};
Future<void> awaitTimelineImages(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await t.pump();
  }
  expect(ready(), isTrue);
  expect(t.takeException(), isNull);
}

Widget timelineImageShell(
  Widget images, {
  double width = 732,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: theme.build(brightness),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: images),
    ),
  ),
);
void main() {
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  for (final width in [362.0, 732.0]) {
    testWidgets(
      'image flex rows preserve intrinsic sizes and stretch peers at $width',
      (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(1024, 900);
        addTearDown(t.view.reset);
        final g = FakeGateway(), held = Completer<Json>();
        g.handler = (method, args) async {
          final source = '${args['source']}';
          if (source.contains('pending')) return held.future;
          if (source.contains('broken')) throw StateError('HTTP 404');
          if (source.contains('invalid')) {
            return {
              'bytes': Uint8List.fromList([1, 2, 3]),
              'mimeType': 'image/png',
            };
          }
          return timelineSvg(
            source.contains('portrait') ? 'portrait' : 'landscape',
          );
        };
        await t.pumpWidget(
          timelineImageShell(
            TimelineImages(
              rows(timelineImageFixture['primaryCases']),
              gateway: g,
            ),
            width: width,
          ),
        );
        await awaitTimelineImages(
          t,
          () =>
              find.byType(SvgPicture).evaluate().length == 2 &&
              find.text('Attachment').evaluate().length == 2,
        );
        final images = find.byType(TimelineAttachmentImage);
        expectImageSize(t.getSize(images.at(0)), const Size(112, 280));
        expectImageSize(
          t.getSize(images.at(1)),
          Size(360, width == 732 ? 280 : 112.5),
        );
        expect(t.getSize(images.at(2)).width, 0);
        expect(
          t.getSize(images.at(2)).height,
          width == 732 ? 280 : t.getSize(images.at(3)).height,
        );
        expect(find.text('Attachment unavailable'), findsNothing);
        expect(g.calls.where((c) => c.$1 == 'image'), hasLength(5));
        await t.pumpWidget(const SizedBox());
        held.complete(timelineSvg('landscape'));
        await g.stream.close();
      },
    );
  }
  testWidgets('far image makes no gateway request before scrolling close', (
    t,
  ) async {
    final scroll = ScrollController(), g = FakeGateway();
    g.handler = (_, _) async => timelineSvg('landscape');
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                const SizedBox(height: 4000),
                TimelineImages([
                  {'url': 'https://images.example/far.svg'},
                ], gateway: g),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(g.calls, isEmpty);
    scroll.jumpTo(2600);
    await t.pump();
    await awaitTimelineImages(
      t,
      () => find.byType(SvgPicture).evaluate().isNotEmpty,
    );
    expect(g.calls.where((c) => c.$1 == 'image'), hasLength(1));
    scroll.jumpTo(0);
    await t.pumpAndSettle();
    expect(g.calls.where((c) => c.$1 == 'image'), hasLength(1));
    await t.pumpWidget(const SizedBox());
    scroll.dispose();
    await g.stream.close();
  });
  for (final retain in [false, true]) {
    testWidgets(
      'source update ${retain ? 'retains tool' : 'remounts message'} geometry until new load',
      (t) async {
        final g = FakeGateway(), pending = Completer<Json>();
        g.handler = (_, args) async => '${args['source']}'.contains('second')
            ? pending.future
            : timelineSvg('landscape');
        Widget shell(String source) => timelineImageShell(
          TimelineImages(
            [
              {'url': source},
            ],
            gateway: g,
            retainOnSourceChange: retain,
          ),
        );
        await t.pumpWidget(shell('/first.svg'));
        await awaitTimelineImages(
          t,
          () => find.byType(SvgPicture).evaluate().isNotEmpty,
        );
        expectImageSize(
          t.getSize(find.byType(TimelineAttachmentImage)),
          const Size(360, 112.5),
        );
        await t.pumpWidget(shell('/second.svg'));
        await t.pump();
        expectImageSize(
          t.getSize(find.byType(TimelineAttachmentImage)),
          retain ? const Size(360, 112.5) : Size.zero,
        );
        pending.complete(timelineSvg('portrait'));
        await awaitTimelineImages(
          t,
          () =>
              t.getSize(find.byType(TimelineAttachmentImage)) ==
              const Size(112, 280),
        );
        await t.pumpWidget(const SizedBox());
        await g.stream.close();
      },
    );
  }
  testWidgets('late source decode cannot replace newer tool image', (t) async {
    final g = FakeGateway(), stale = Completer<Json>();
    g.handler = (_, args) async => '${args['source']}'.contains('stale')
        ? stale.future
        : timelineSvg('portrait');
    Widget shell(String source) => timelineImageShell(
      TimelineImages(
        [
          {'url': source},
        ],
        gateway: g,
        retainOnSourceChange: true,
      ),
    );
    await t.pumpWidget(shell('/stale.svg'));
    await t.pump();
    await t.pumpWidget(shell('/current.svg'));
    await awaitTimelineImages(
      t,
      () => find.byType(SvgPicture).evaluate().isNotEmpty,
    );
    stale.complete(timelineSvg('landscape'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pumpAndSettle();
    expect(
      t.getSize(find.byType(TimelineAttachmentImage)),
      const Size(112, 280),
    );
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });
  testWidgets(
    'timeline image urls are page content and never select a credentialed request',
    (t) async {
      final g = FakeGateway();
      g.handler = (_, _) async => timelineSvg('landscape');
      final sources = [
        '/api/sessions/s/attachments/a1',
        '//gateway.example/api/sessions/s/attachments/a2',
        'https://gateway.example/api/sessions/s/attachments/a3',
        'https://images.example/a.svg',
        '/timeline-image/landscape.svg?id=content',
      ];
      await t.pumpWidget(
        timelineImageShell(
          TimelineImages([
            for (final source in sources) {'url': source},
          ], gateway: g),
        ),
      );
      await awaitTimelineImages(
        t,
        () => find.byType(SvgPicture).evaluate().length == sources.length,
      );
      // Only the credential-free image request is ever used, with the source alone.
      expect(g.calls.map((c) => c.$1).toSet(), {'image'});
      expect(
        g.calls.map((c) => c.$2['source']).toList(),
        unorderedEquals(sources),
      );
      expect(g.calls.every((c) => c.$2.keys.toList().length == 1), isTrue);
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );
}
