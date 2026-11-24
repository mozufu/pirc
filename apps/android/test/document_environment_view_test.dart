import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_environment.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'live_test.dart' show theme;

class _CapturedScripts extends NativeDocumentScripts {
  _CapturedScripts() : super(Gateway());
  final started = <NativeDocumentEnvironment>[];
  @override
  Future<void> start({
    required String source,
    required String url,
    String? referrerPolicy,
    String? blobCreatorUrl,
    String referrer = '',
    Json? history,
    String? storageSessionKey,
  }) async {
    started.add(environment);
    ready = true;
  }

  @override
  Future<bool> dispatch(
    String id,
    String type,
    List<Json> controls, {
    String? submitter,
    Json? eventData,
    bool modalBackdrop = false,
    bool modalTouchCompatibility = false,
  }) async => false;
}

void main() {
  final fixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-media-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  const queryIds = {
    'width-min-768',
    'height-min-1024',
    'scheme-dark',
    'orientation-portrait',
    'resolution-1dppx',
    'pointer-fine',
  };
  for (final row in fixture['viewportMatrix']['cases'] as List) {
    testWidgets('actual Flutter media colors match ${row['id']}', (t) async {
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final config = row['configured'] as Map;
      final observations = (row['queryObservations'] as List)
          .where((q) => queryIds.contains(q['id']))
          .toList();
      final markup =
          '<html><body>${List.generate(observations.length, (i) => '<p id="p$i">Probe$i</p>').join()}</body></html>';
      final bytes = Uint8List.fromList(utf8.encode(markup));
      final content = NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/html',
        charset: 'utf-8',
      );
      final document = NativeFetchedDocument(
        id: 1,
        url: 'https://media.test/',
        status: 200,
        bytes: bytes,
        mimeType: 'text/html',
        content: content,
        headers: {},
        stylesheets: [
          NativeDocumentStylesheet(
            'p { color:rgb(1,2,3); } ${List.generate(observations.length, (i) => '@media ${observations[i]['query']} { #p$i {color:rgb(4,5,6)} }').join()}',
            baseUrl: 'https://media.test/',
          ),
        ],
      );
      addTearDown(document.dispose);
      t.view.devicePixelRatio = (row['devicePixelRatio'] as num).toDouble();
      t.view.physicalSize =
          Size(
            (row['innerWidth'] as num).toDouble(),
            (row['innerHeight'] as num).toDouble(),
          ) *
          t.view.devicePixelRatio;
      await t.pumpWidget(
        MaterialApp(
          theme: theme
              .build(
                config['colorScheme'] == 'dark'
                    ? Brightness.dark
                    : Brightness.light,
              )
              .copyWith(platform: TargetPlatform.linux),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(
                (config['rootFontScale'] as num).toDouble(),
              ),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: NativeFetchedDocumentView(
              document: document,
              gateway: Gateway(),
              onLink: (_) {},
              onSubmit: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      for (var i = 0; i < observations.length; i++) {
        final text = t
            .widgetList<RichText>(find.byType(RichText))
            .singleWhere((r) => r.text.toPlainText() == 'Probe$i');
        expect(
          text.text.style?.color,
          observations[i]['cssApplied'] == true
              ? const Color.fromRGBO(4, 5, 6, 1)
              : const Color.fromRGBO(1, 2, 3, 1),
          reason: '${row['id']} ${observations[i]['query']}',
        );
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'document viewport reaches first script and responsive styles before resizing',
    (t) async {
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final bytes = Uint8List.fromList(
        utf8.encode(
          '<html><body><p id="probe">Viewport</p><input value="Draft"><script></script></body></html>',
        ),
      );
      final content = NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/html',
        charset: 'utf-8',
      );
      final scripts = _CapturedScripts()..content = content;
      final document = NativeFetchedDocument(
        id: 1,
        url: 'https://example.test/',
        status: 200,
        bytes: bytes,
        mimeType: 'text/html',
        content: content,
        headers: {},
        stylesheets: const [
          NativeDocumentStylesheet(
            'body{margin:0} #probe{color:rgb(1,2,3)} @media (min-width:600px) and (min-height:450px) and (prefers-color-scheme:dark) and (resolution:2dppx){#probe{color:rgb(4,5,6)}}',
            baseUrl: 'https://example.test/',
          ),
        ],
      )..scripts = scripts;
      addTearDown(document.dispose);
      Future<void> render({
        required double screenWidth,
        required double screenHeight,
        required double width,
        required double height,
        required double dpr,
        bool dark = false,
        bool motion = false,
        double textScale = 1,
      }) async {
        t.view.devicePixelRatio = dpr;
        t.view.physicalSize = Size(screenWidth * dpr, screenHeight * dpr);
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: motion,
                textScaler: TextScaler.linear(textScale),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  height: height,
                  child: NativeFetchedDocumentView(
                    document: document,
                    gateway: Gateway(),
                    onLink: (_) {},
                    onSubmit: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      Color? color() => t
          .widgetList<RichText>(find.byType(RichText))
          .singleWhere((r) => r.text.toPlainText() == 'Viewport')
          .text
          .style
          ?.color;
      await render(
        screenWidth: 390,
        screenHeight: 844,
        width: 300,
        height: 400,
        dpr: 1,
      );
      expect(scripts.started, hasLength(1));
      expect(scripts.started.single.width, 300);
      expect(scripts.started.single.height, 400);
      expect(scripts.started.single.screenWidth, 390);
      expect(scripts.started.single.screenHeight, 844);
      expect(color(), const Color.fromRGBO(1, 2, 3, 1));
      await t.enterText(find.byType(EditableText), 'Retained edit');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pumpAndSettle();
      final controller = t
          .widget<EditableText>(find.byType(EditableText))
          .controller;
      await render(
        screenWidth: 768,
        screenHeight: 1024,
        width: 600,
        height: 500,
        dpr: 2,
        dark: true,
        motion: true,
        textScale: 2,
      );
      expect(scripts.started, hasLength(1));
      expect(
        scripts.environment.toJson(),
        const NativeDocumentEnvironment(
          width: 600,
          height: 500,
          screenWidth: 768,
          screenHeight: 1024,
          devicePixelRatio: 2,
          dark: true,
          reducedMotion: true,
        ).toJson(),
      );
      expect(color(), const Color.fromRGBO(4, 5, 6, 1));
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller,
        same(controller),
      );
      expect(controller.text, 'Retained edit');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
