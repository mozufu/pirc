// Android scroll/visibility acceptance; in-memory image Gateway, real Flutter SVG.
import 'package:pirc_mobile/rendering/remote_content_gate.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_mobile/rendering/html_syntax.dart';
import 'package:pirc_mobile/rendering/native_html.dart';
import 'package:pirc_mobile/rendering/native_image_density.dart';

import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:integration_test/integration_test.dart';

late PircTheme theme;

final _svg = {
  'bytes': Uint8List.fromList(
    utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">'
      '<rect width="100" height="50" fill="red"/></svg>',
    ),
  ),
  'mimeType': 'image/svg+xml',
};

Widget _page(FakeGateway gateway, ScrollController controller, String source) =>
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          controller: controller,
          child: NativeHtmlDocument(
            nodes: [NativeHtmlRaw(source)],
            style: const TextStyle(fontSize: 15),
            styles: md.MarkdownStyleSheet(),
            builders: const {},
            imageBuilder: (source, title, alt) => NativeMarkdownImage(
              gateway: gateway,
              source: source,
              title: title,
              alt: alt,
            ),
          ),
        ),
      ),
    );

List<String> _imageSources(FakeGateway gateway) => gateway.calls
    .where((call) => call.$1 == 'image')
    .map((call) => '${call.$2['source']}')
    .toList();

Future<void> _waitForSource(
  WidgetTester tester,
  FakeGateway gateway,
  String source,
) async {
  for (var i = 0; i < 60 && !_imageSources(gateway).contains(source); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(_imageSources(gateway), contains(source));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // These suites exercise the image/media loaders themselves, not the hold-back.
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  setUp(() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    expect(
      view.physicalSize.height / view.devicePixelRatio,
      lessThan(1000),
      reason: "Run owned emulator in phone viewport (density 480)",
    );
  });
  setUpAll(() async {
    theme = await PircTheme.load();
  });
  testWidgets(
    'HTML lazy images load near the viewport once; eager remains eager',
    (tester) async {
      final gateway = FakeGateway()..handler = (_, _) async => _svg;
      final controller = ScrollController();
      addTearDown(controller.dispose);
      const source =
          '<img src="/eager.svg" width="100" height="50">\n'
          '<div style="height:1600px"></div>\n'
          '<img loading="lazy" src="/lazy.svg" width="100" height="50">';

      await tester.pumpWidget(_page(gateway, controller, source));
      expect(_imageSources(gateway), ['/eager.svg']);

      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await _waitForSource(tester, gateway, '/lazy.svg');
      await tester.pumpAndSettle();

      controller.jumpTo(0);
      await tester.pump();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_imageSources(gateway), ['/eager.svg', '/lazy.svg']);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await gateway.stream.close();
    },
  );

  testWidgets(
    'offscreen source changes defer requests and ignore late replies',
    (tester) async {
      final gateway = FakeGateway();
      final oldReply = Completer<dynamic>();
      gateway.handler = (_, args) =>
          args['source'] == '/old.svg' ? oldReply.future : Future.value(_svg);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      String sourceFor(String image) =>
          '<div style="height:1600px"></div>\n'
          '<img loading="lazy" src="$image" width="100" height="50">';

      await tester.pumpWidget(
        _page(gateway, controller, sourceFor('/old.svg')),
      );
      expect(_imageSources(gateway), isEmpty);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await _waitForSource(tester, gateway, '/old.svg');
      controller.jumpTo(0);
      await tester.pump();
      await tester.pumpWidget(
        _page(gateway, controller, sourceFor('/new.svg')),
      );
      expect(_imageSources(gateway), ['/old.svg']);

      oldReply.complete(_svg);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(find.byType(SvgPicture), findsNothing);
      expect(_imageSources(gateway), ['/old.svg']);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await _waitForSource(tester, gateway, '/new.svg');
      await tester.pumpAndSettle();
      expect(_imageSources(gateway), ['/old.svg', '/new.svg']);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await gateway.stream.close();
    },
  );

  testWidgets('lazy HTML image outside a Scrollable loads eagerly', (
    tester,
  ) async {
    final gateway = FakeGateway()..handler = (_, _) async => _svg;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: NativeImageDensity(
            density: 1,
            loadingLazy: true,
            child: NativeMarkdownImage(
              gateway: gateway,
              source: Uri.parse('/standalone.svg'),
            ),
          ),
        ),
      ),
    );

    expect(_imageSources(gateway), ['/standalone.svg']);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await gateway.stream.close();
  });
}

class FakeGateway extends Gateway {
  final stream = StreamController<Json>.broadcast(sync: true);
  final calls = <(String, Json)>[];
  Future<dynamic> Function(String, Json)? handler;
  @override
  Stream<Json> get events => stream.stream;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    calls.add((method, args));
    return handler!(method, args);
  }
}
