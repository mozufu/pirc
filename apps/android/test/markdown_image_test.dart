import 'package:pirc_mobile/live/remote_content_gate.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/rendering/native_markdown.dart';
import 'package:pirc_mobile/rendering/svg_dimensions.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_mobile/rendering/native_image_density.dart';
import 'live_test.dart' show theme, FakeGateway;
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

final imageFixture = obj(
  jsonDecode(
    File(
      '../../fixtures/mobile-parity/markdown-images.json',
    ).readAsStringSync(),
  ),
);
Json svgData([String key = 'svg']) => {
  'bytes': Uint8List.fromList(utf8.encode(imageFixture[key])),
  'mimeType': 'image/svg+xml',
};
Future<void> waitImage(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 60 && !ready(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await t.pump();
  }
  expect(ready(), true);
  expect(t.takeException(), isNull);
}

Widget imageShell(Widget child, {double width = 390}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Scaffold(
    body: SizedBox(width: width, child: child),
  ),
);
void main() {
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  testWidgets('HTML image crossorigin changes reach native image transport', (
    t,
  ) async {
    final g = FakeGateway();
    final requests = <Json>[];
    g.handler = (method, args) async {
      requests.add(args);
      return svgData();
    };
    try {
      for (final mode in ['anonymous', 'use-credentials']) {
        await t.pumpWidget(
          imageShell(
            NativeImageDensity(
              density: 1,
              crossOrigin: mode,
              child: NativeMarkdownImage(
                gateway: g,
                source: Uri.parse('/cors.svg'),
              ),
            ),
          ),
        );
        await waitImage(
          t,
          () =>
              requests.length == (mode == 'anonymous' ? 1 : 2) &&
              find.byType(SvgPicture).evaluate().isNotEmpty,
        );
        expect(requests.last['crossOrigin'], mode);
      }
    } finally {
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    }
  });

  test('SVG intrinsic dimensions match Chromium measurements', () {
    for (final c in rows(imageFixture['svgSizes'])) {
      expect(
        svgImageSize('<svg ${c['attrs']}/>'),
        Size((c['width'] as num).toDouble(), (c['height'] as num).toDouble()),
        reason: '${c['attrs']}',
      );
    }
  });
  testWidgets(
    'wide SVG uses viewport width before constraining to the message',
    (t) async {
      final g = FakeGateway();
      g.handler = (_, _) async => svgData('wide');
      await t.pumpWidget(
        imageShell(
          NativeMarkdownImage(gateway: g, source: Uri.parse('/wide.svg')),
        ),
      );
      await waitImage(t, () => find.byType(SvgPicture).evaluate().isNotEmpty);
      expect(t.getSize(find.byType(SvgPicture)), const Size(390, 182));
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );

  for (final sizeCase in [
    ('1e2', '5E1', const Size(100, 50)),
    ('0', '60', const Size(0, 60)),
    ('100', '0', const Size(100, 0)),
  ]) {
    testWidgets(
      'SVG native image retains viewport ${sizeCase.$1} x ${sizeCase.$2}',
      (t) async {
        final g = FakeGateway();
        final source =
            '<svg xmlns="http://www.w3.org/2000/svg" width="${sizeCase.$1}" height="${sizeCase.$2}" viewBox="0 0 100 50"><rect width="100" height="50" fill="red"/></svg>';
        await t.pumpWidget(
          imageShell(
            NativeMarkdownImage(
              gateway: g,
              source: Uri.dataFromString(source, mimeType: 'image/svg+xml'),
            ),
          ),
        );
        final viewport = find.descendant(
          of: find.byType(NativeMarkdownImage),
          matching: find.byWidgetPredicate(
            (w) =>
                w is SizedBox &&
                w.width == sizeCase.$3.width &&
                w.height == sizeCase.$3.height,
          ),
        );
        await waitImage(t, () => viewport.evaluate().isNotEmpty);
        expect(t.getSize(viewport.first), sizeCase.$3);
        expect(g.calls, isEmpty);
        await t.pumpWidget(const SizedBox());
        await g.stream.close();
      },
    );
  }

  testWidgets('relative linked SVG keeps URL and opens workspace target on tap', (
    t,
  ) async {
    final g = FakeGateway();
    g.handler = (_, _) async => svgData();
    String? target;
    await t.pumpWidget(
      imageShell(
        RichTextBody(
          '[![Chart](images/chart.svg?theme=dark#icon "Chart title")](../src/main.ts:4)',
          gateway: g,
          linkBase: 'docs',
          onFile: (v) => target = v,
        ),
      ),
    );
    await waitImage(t, () => find.byType(SvgPicture).evaluate().isNotEmpty);
    expect(g.calls.single.$1, 'image');
    expect(g.calls.single.$2, {'source': 'images/chart.svg?theme=dark#icon'});
    expect(t.getSize(find.byType(SvgPicture)), const Size(300, 140));
    expect(find.byTooltip('Chart title'), findsOneWidget);
    await t.tap(find.byType(SvgPicture));
    expect(target, 'src/main.ts#L4');
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });
  testWidgets('SVG Markdown table image keeps query and fragment', (t) async {
    final g = FakeGateway();
    g.handler = (_, _) async => svgData();
    await t.pumpWidget(
      imageShell(
        RichTextBody(
          '| Chart |\n| --- |\n| ![Chart](images/chart.svg?theme=dark#icon) |',
          gateway: g,
        ),
      ),
    );
    await waitImage(t, () => find.byType(SvgPicture).evaluate().isNotEmpty);
    expect(g.calls.single.$2, {'source': 'images/chart.svg?theme=dark#icon'});
    expect(t.getSize(find.byType(SvgPicture)), const Size(300, 140));
    expect(
      t.getSize(find.byKey(const ValueKey('native-markdown-table'))).width,
      390,
    );
    expect(t.getSize(find.byType(Table)).width, closeTo(388, 0.1));
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });
  for (final (scale, expectedHeight, expectedImageTop) in [
    (1.0, 192.375, 40.6875),
    (2.0, 217.78125, 61.390625),
  ]) {
    testWidgets(
      'table image preserves the pinned inline baseline line box at scale $scale',
      (t) async {
        await t.runAsync(loadParityFonts);
        t.view.physicalSize = const Size(390, 500);
        t.view.devicePixelRatio = 1;
        t.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(t.view.reset);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        final g = FakeGateway();
        g.handler = (_, _) async => svgData();
        final data = theme.build(Brightness.light);
        await t.pumpWidget(
          MaterialApp(
            theme: data.copyWith(
              textTheme: data.textTheme.apply(fontFamily: 'Arial'),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: RichTextBody(
                  '| Chart |\n| --- |\n| ![Chart](images/chart.svg?theme=dark#icon) |',
                  gateway: g,
                ),
              ),
            ),
          ),
        );
        await waitImage(t, () => find.byType(SvgPicture).evaluate().isNotEmpty);
        expect(
          t.getSize(find.byType(Table)).height,
          closeTo(expectedHeight, 0.5),
          reason: 'Pinned browser table height at text scale $scale',
        );
        expect(
          t.getRect(find.byType(SvgPicture)).top,
          closeTo(expectedImageTop, 0.55),
          reason: 'Pinned browser image baseline at text scale $scale',
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await g.stream.close();
      },
    );
  }

  testWidgets('table image error and tooltip builder support dry baselines', (
    t,
  ) async {
    final g = FakeGateway();
    g.handler = (_, _) async => throw StateError('image unavailable');
    await t.pumpWidget(
      imageShell(
        RichTextBody(
          '| Image |\n| --- |\n| ![Chart alternative](images/missing.svg "Image title") |',
          gateway: g,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Chart alternative'), findsOneWidget);
    expect(find.byType(Tooltip), findsWidgets);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });

  testWidgets('narrow Markdown table image shrinks to its cell width', (
    t,
  ) async {
    final g = FakeGateway();
    g.handler = (_, _) async => svgData();
    await t.pumpWidget(
      imageShell(
        RichTextBody(
          '| Chart |\n| --- |\n| ![Chart](images/chart.svg?variant=narrow#icon) |',
          gateway: g,
        ),
        width: 240,
      ),
    );
    await waitImage(t, () => find.byType(SvgPicture).evaluate().isNotEmpty);
    expect(g.calls.single.$2, {
      'source': 'images/chart.svg?variant=narrow#icon',
    });
    final imageSize = t.getSize(find.byType(SvgPicture));
    final tableViewport = t.getSize(
      find.byKey(const ValueKey('native-markdown-table')),
    );
    final tableContent = t.getSize(find.byType(Table));
    expect(imageSize.width, closeTo(217.96875, 0.1));
    expect(imageSize.height, closeTo(101.71875, 0.1));
    expect(imageSize.width / imageSize.height, closeTo(300 / 140, 1e-3));
    expect(tableViewport.width, 240);
    expect(tableContent.width, closeTo(238, 0.1));
    expect(imageSize.width, lessThan(tableContent.width));
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });
  testWidgets('image fragment survives nested Markdown table image scope', (
    t,
  ) async {
    // Keep this builder layout-free so this test isolates nested URI
    // forwarding; the real NativeMarkdownImage table regression above covers
    // intrinsic sizing and dry layout.
    final sources = <Uri>[];
    var generation = 0;
    late StateSetter refresh;
    await t.pumpWidget(
      imageShell(
        StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NativeMarkdown(
                  source:
                      '| Chart |\n| --- |\n| ![Chart](images/chart.svg?from=table#symbol) |',
                  imageBuilder: (uri, _, _) {
                    sources.add(uri);
                    return const SizedBox(width: 12, height: 12);
                  },
                ),
                Text('build $generation'),
              ],
            );
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    const expected = 'images/chart.svg?from=table#symbol';
    expect(sources, isNotEmpty);
    expect(sources.map((uri) => uri.toString()), everyElement(expected));
    final beforeRefresh = sources.length;
    refresh(() => generation++);
    await t.pumpAndSettle();
    expect(sources.length, greaterThan(beforeRefresh));
    expect(sources.map((uri) => uri.toString()), everyElement(expected));
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'dimension-looking image fragment stays in URL and keeps intrinsic size',
    (t) async {
      final g = FakeGateway();
      g.handler = (_, _) async => svgData();
      await t.pumpWidget(
        imageShell(
          RichTextBody(
            '![Chart](images/chart.svg?variant=full#100x50)',
            gateway: g,
          ),
        ),
      );
      await waitImage(t, () => find.byType(SvgPicture).evaluate().isNotEmpty);
      expect(g.calls.single.$2, {
        'source': 'images/chart.svg?variant=full#100x50',
      });
      expect(t.getSize(find.byType(SvgPicture)), const Size(300, 140));
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );
  testWidgets(
    'data raster and SVG decode natively without network and fit width',
    (t) async {
      final g = FakeGateway();
      for (final source in [
        Uri.dataFromString(imageFixture['wide'], mimeType: 'image/svg+xml'),
        Uri.dataFromBytes(
          base64Decode(imageFixture['jpeg']),
          mimeType: 'image/jpeg',
        ),
      ]) {
        await t.pumpWidget(
          imageShell(
            NativeMarkdownImage(gateway: g, source: source, alt: 'Image'),
            width: 240,
          ),
        );
        await waitImage(
          t,
          () =>
              find.byType(SvgPicture).evaluate().isNotEmpty ||
              find.byType(Image).evaluate().isNotEmpty,
        );
        final f = find.byType(
          source.data!.mimeType == 'image/svg+xml' ? SvgPicture : Image,
        );
        expect(t.getSize(f).width, 240);
        expect(
          t.getSize(f).height,
          closeTo(source.data!.mimeType == 'image/svg+xml' ? 112 : 150, .01),
        );
      }
      expect(g.calls, isEmpty);
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );
  testWidgets('old image response cannot replace a changed source', (t) async {
    final g = FakeGateway(), old = Completer<Json>();
    g.handler = (_, a) =>
        a['source'] == '/old.svg' ? old.future : Future.value(svgData('wide'));
    await t.pumpWidget(
      imageShell(
        NativeMarkdownImage(gateway: g, source: Uri.parse('/old.svg')),
      ),
    );
    await t.pumpWidget(
      imageShell(
        NativeMarkdownImage(gateway: g, source: Uri.parse('/new.svg')),
      ),
    );
    await waitImage(t, () => find.byType(SvgPicture).evaluate().isNotEmpty);
    old.complete(svgData());
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump();
    expect(t.getSize(find.byType(SvgPicture)).width, 390);
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });
  testWidgets(
    'failed and disallowed images show alt without buttons or raw exceptions',
    (t) async {
      final g = FakeGateway();
      g.handler = (_, _) async => throw const FormatException('private detail');
      for (final source in [
        '/missing.png',
        'file:///tmp/private.png',
        'javascript:alert(1)',
      ]) {
        await t.pumpWidget(
          imageShell(
            NativeMarkdownImage(
              gateway: g,
              source: Uri.parse(source),
              alt: 'Missing image',
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('Missing image'), findsOneWidget);
        expect(find.byIcon(LucideIcons.imageOff), findsOneWidget);
        expect(find.byType(TextButton), findsNothing);
        expect(find.textContaining('private detail'), findsNothing);
      }
      expect(g.calls.length, 1);
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );
}
