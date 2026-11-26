import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_render/src/html_syntax.dart';

import 'support/render_theme.dart';

/// M8 step 7: an AVIF image is shown when the Android `images` channel reports
/// support (converted to PNG by `normalizeAvif`), and the `<picture>` fallback
/// is shown when it does not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.mozufu.pirc/images');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => NativeRasterImages.debugRunsOnAndroid = true);
  tearDown(() {
    NativeRasterImages.debugRunsOnAndroid = null;
    NativeRasterImages.avifSupported = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// Answers the channel like Android with or without AVIF and records calls.
  List<MethodCall> android({required bool avif}) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'imageCapabilities':
          return {'avif': avif};
        case 'normalizeAvif':
          if (!avif) throw PlatformException(code: 'INVALID');
          return _converted;
      }
      return null;
    });
    return calls;
  }

  /// A fetched document (not chat Markdown, whose policy drops `data:` in
  /// `srcset`) with an AVIF `<picture>` source and a PNG fallback.
  Future<void> pumpPicture(WidgetTester t, {String? avifSource}) async {
    await t.pumpWidget(
      MaterialApp(
        theme: renderTestTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<picture><source type="image/avif" srcset="${avifSource ?? 'data:image/avif;base64,${base64Encode(_avif)}'}">'
                  '<img src="data:image/png;base64,${base64Encode(_fallback)}" alt="photo"></picture>',
                ),
              ],
              style: const TextStyle(fontSize: 15),
              styles: MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  /// The bytes of every in-memory image on screen.
  List<Uint8List> shownImages(WidgetTester t) => [
    for (final image in t.widgetList<Image>(find.byType(Image)))
      if (image.image case final MemoryImage memory) memory.bytes,
  ];

  testWidgets('AVIF is converted and shown when the channel supports it', (
    t,
  ) async {
    final calls = android(avif: true);
    await NativeRasterImages.loadCapabilities();
    expect(NativeRasterImages.avifSupported, isTrue);

    await pumpPicture(t);

    expect(calls.map((call) => call.method), [
      'imageCapabilities',
      'normalizeAvif',
    ]);
    expect(calls.last.arguments, {'bytes': _avif});
    expect(shownImages(t), [_converted]);
  });

  testWidgets('a remote AVIF source gives way to the fallback', (t) async {
    // Only in-memory AVIF can be converted; the platform decoder would get
    // a remote one's alpha wrong.
    final calls = android(avif: true);
    await NativeRasterImages.loadCapabilities();

    await pumpPicture(t, avifSource: 'https://img.example.test/photo.avif');

    expect(calls.map((call) => call.method), ['imageCapabilities']);
    expect(shownImages(t), [_fallback]);
    expect(
      find.byKey(const ValueKey('remote-content-placeholder')),
      findsNothing,
    );
  });

  testWidgets('the fallback is shown when the channel has no AVIF', (t) async {
    final calls = android(avif: false);
    await NativeRasterImages.loadCapabilities();
    expect(NativeRasterImages.avifSupported, isFalse);

    await pumpPicture(t);

    expect(calls.map((call) => call.method), ['imageCapabilities']);
    expect(shownImages(t), [_fallback]);
  });

  testWidgets('without the channel the fallback is shown', (t) async {
    // As on an engine without the feature.
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw MissingPluginException(),
    );
    await NativeRasterImages.loadCapabilities();
    expect(NativeRasterImages.avifSupported, isFalse);

    await pumpPicture(t);

    expect(shownImages(t), [_fallback]);
  });

  testWidgets('an AVIF Android cannot convert shows the alt text', (t) async {
    final calls = android(avif: true);
    await NativeRasterImages.loadCapabilities();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'INVALID');
    });

    await pumpPicture(t);

    expect(calls.last.method, 'normalizeAvif');
    expect(shownImages(t), isEmpty);
    expect(find.text('photo'), findsOneWidget);
  });
}

/// Not a real AVIF file: the channel is mocked. Only the `ftyp` box matters.
final _avif = Uint8List.fromList([
  0, 0, 0, 24, ...ascii.encode('ftypavifmif1'), 0, 0, 0, 0, 0, 0, 0, 0, //
]);

/// What `normalizeAvif` returns: a 2 × 1 PNG.
final _converted = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGNgaPj/H4QBEvsE/dOyRH0AAAAASUVORK5CYII=',
);

/// The `<img>` fallback: a 1 × 1 PNG.
final _fallback = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
