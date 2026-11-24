import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_render/src/html_input_sizing.dart';

import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

// Comparison-only host fonts. The extractor emits standalone PingFang TC
// Regular/Semibold faces under ignored build output; they are never bundled.
Future<Map<String, Object?>>? _hostFontAliases;

Future<Map<String, Object?>> _loadHostFontAliases() =>
    _hostFontAliases ??= _loadHostFontAliasesOnce();

Future<Map<String, Object?>> _loadHostFontAliasesOnce() async {
  final manifestFile = File('build/parity/font-fixtures/manifest.json');
  if (!manifestFile.existsSync()) {
    throw StateError(
      'Run node tool/parity/extract_pingfang_tc_faces.mjs before this capture.',
    );
  }
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final outputFaces = (manifest['outputFaces'] as List)
      .cast<Map<String, dynamic>>();
  Map<String, dynamic> face(String subfamily, int index) =>
      outputFaces.singleWhere(
        (candidate) =>
            candidate['subfamily'] == subfamily && candidate['index'] == index,
      );
  final regular = face('Regular', 2);
  final semibold = face('Semibold', 10);
  final pingfang = [
    'build/parity/font-fixtures/${regular['output']}',
    'build/parity/font-fixtures/${semibold['output']}',
  ];
  for (var index = 0; index < pingfang.length; index++) {
    final file = File(pingfang[index]);
    final expectedBytes =
        (index == 0 ? regular['outputBytes'] : semibold['outputBytes']) as int;
    if (!file.existsSync() || file.lengthSync() != expectedBytes) {
      throw StateError(
        'Extracted PingFang face is missing or changed: ${file.path}',
      );
    }
  }
  const supplemental = '/System/Library/Fonts/Supplemental/';
  final arial = <String>[
    '${supplemental}Arial.ttf',
    '${supplemental}Arial Bold.ttf',
    '${supplemental}Arial Italic.ttf',
    '${supplemental}Arial Bold Italic.ttf',
  ];
  Future<List<String>> register(String family, List<String> paths) async {
    final available = <String>[
      for (final path in paths)
        if (File(path).existsSync()) path,
    ];
    if (available.isEmpty) return available;
    final loader = FontLoader(family);
    for (final path in available) {
      loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
    }
    await loader.load();
    return available;
  }

  final serifPaths = await register('serif', pingfang);
  final timesPaths = await register('Times', pingfang);
  final arialPaths = await register('sans-serif', arial);
  if (serifPaths.length != 2 || timesPaths.length != 2) {
    throw StateError(
      'Both PingFang TC comparison faces must load for each alias.',
    );
  }
  return {
    'serif': serifPaths,
    'Times': timesPaths,
    'sans-serif': arialPaths,
    'pingFangTtcSource': {
      'path': manifest['sourcePath'],
      'sha256': manifest['sourceSha256'],
      'faceCount': manifest['faceCount'],
      'regular': {
        'index': regular['index'],
        'postScriptName': regular['postScriptName'],
        'sha256': regular['outputSha256'],
      },
      'semibold': {
        'index': semibold['index'],
        'postScriptName': semibold['postScriptName'],
        'sha256': semibold['outputSha256'],
      },
      'selection': manifest['selection'],
      'glyphTablesUnchanged': true,
    },
  };
}

Map<String, Object?> _rectMap(ui.Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};

TextStyle _firstTextStyle(InlineSpan span, TextStyle inherited) {
  if (span is! TextSpan) return inherited;
  final style = span.style == null ? inherited : inherited.merge(span.style);
  if ((span.text ?? '').trim().isNotEmpty) return style;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final found = _firstTextStyle(child, style);
    if (found != style ||
        child is TextSpan && child.text?.trim().isNotEmpty == true) {
      return found;
    }
  }
  return style;
}

class _TextCapture {
  const _TextCapture(this.widget, this.rect, this.style);
  final RichText widget;
  final ui.Rect rect;
  final TextStyle style;
  String get plainText =>
      widget.text.toPlainText().replaceAll('\uFFFC', '').trim();
  Map<String, Object?> toJson() => {
    'text': plainText,
    'rect': _rectMap(rect),
    'fontFamily': style.fontFamily,
    'fontSize': style.fontSize,
    'lineHeight': style.height,
    'colorArgb': style.color?.toARGB32(),
  };
}

List<_TextCapture> _textCaptures(WidgetTester tester, String text) {
  final captures = <_TextCapture>[];
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    if (widget.text.toPlainText().replaceAll('\uFFFC', '').trim() != text) {
      continue;
    }
    final finder = find.byWidget(widget);
    final inherited = DefaultTextStyle.of(tester.element(finder)).style;
    captures.add(
      _TextCapture(
        widget,
        tester.getRect(finder),
        _firstTextStyle(widget.text, inherited),
      ),
    );
  }
  captures.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  return captures;
}

void _expectFontSize(double? actual, double expected, String label) {
  expect(actual, isNotNull, reason: '$label font size is present');
  expect(
    (actual! - expected).abs(),
    lessThan(0.01),
    reason: '$label font size',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-navigation.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final web =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-navigation-expected.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final htmlSource = fixture['responseStyleSource'] as String;
  final responseUrl = '${web['origin']}/nav/style-probe';
  final responseBytes = Uint8List.fromList(utf8.encode(htmlSource));

  for (final width in [390.0, 768.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('native raw HTML response ${width.toInt()} ${brightness.name}', (
        tester,
      ) async {
        final diagnosticSteps = <String>[];
        void markStep(String step) {
          diagnosticSteps.add(step);
          debugPrint('HTML document capture step: $step');
        }

        late Map<String, Object?> hostFontAliases;
        markStep('font-load-start');
        await tester.runAsync(() async {
          await loadParityFonts();
          hostFontAliases = await _loadHostFontAliases();
        });
        markStep('font-load-complete');
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = ui.Size(width, 844);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

        final gateway = Gateway();
        final content = NativeHtmlDocumentContent.fromBytes(
          responseBytes,
          mimeType: 'text/html',
          charset: 'utf-8',
        );
        final document = NativeFetchedDocument(
          id: 0,
          url: responseUrl,
          status: 200,
          bytes: responseBytes,
          mimeType: 'text/html',
          content: content,
          headers: const {'Content-Type': 'text/html; charset=utf-8'},
        );
        var cleanupComplete = false;
        Future<void> cleanup() async {
          if (cleanupComplete) return;
          markStep('teardown-start');
          markStep('widget-unmount-start');
          await tester.pumpWidget(const SizedBox.shrink());
          markStep('widget-unmount-complete');
          await tester.pump(const Duration(seconds: 2));
          markStep('post-unmount-pump-complete');
          document.dispose();
          markStep('document-dispose-complete');
          cleanupComplete = true;
          markStep('teardown-complete');
        }

        addTearDown(cleanup);
        final boundaryKey = GlobalKey();
        markStep('pump-widget-start');
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.build(brightness),
              home: Material(
                type: MaterialType.transparency,
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
        markStep('pump-widget-complete');
        markStep('pump-and-settle-start');
        await tester.pumpAndSettle();
        markStep('pump-and-settle-complete');
        expect(tester.takeException(), isNull);

        final bodyFinder = find.byType(HtmlWidget);
        final textField = tester
            .widgetList<NativeHtmlTextFieldWidget>(
              find.byType(NativeHtmlTextFieldWidget),
            )
            .singleWhere(
              (field) => field.field.initialValue == 'response input',
            );
        final button = tester
            .widgetList<NativeHtmlButtonWidget>(
              find.byType(NativeHtmlButtonWidget),
            )
            .singleWhere((widget) => widget.button.label == 'Response button');
        final heading = _textCaptures(
          tester,
          'Local navigation response',
        ).first;
        final paragraph = _textCaptures(tester, 'Static response body.').single;
        final anchor = _textCaptures(tester, 'Same response').single;
        final buttonLabel = _textCaptures(tester, 'Response button').single;
        expect(bodyFinder, findsOneWidget);
        expect(
          tester.getRect(find.byType(NativeFetchedDocumentView)).size,
          ui.Size(width, 844),
        );
        markStep('widget-measurements-complete');

        final inputElement = tester.element(find.byWidget(textField));
        final inputGlyphPainter = TextPainter(
          text: TextSpan(
            text: 'x',
            style: textField.textStyle.copyWith(height: kTextHeightNone),
          ),
          textDirection: Directionality.of(inputElement),
          textScaler: MediaQuery.textScalerOf(inputElement),
        )..layout();
        final inputGlyphLine = inputGlyphPainter.computeLineMetrics().single;
        final inputAverageCharacterWidth =
            HtmlInputSizing.effectiveAverageCharacterWidth(
              inputGlyphPainter.width,
            );
        final inputMaximumCharacterWidth = math.max(
          inputAverageCharacterWidth,
          inputGlyphLine.ascent.roundToDouble(),
        );
        final inputIntrinsicContentWidth =
            HtmlInputSizing.textFieldIntrinsicInlineSize(
              preferredCharacterCount: textField.field.size,
              averageCharacterWidth: inputAverageCharacterWidth,
              maximumCharacterWidth: inputMaximumCharacterWidth,
            );
        final inputBorderBox = tester.getRect(find.byWidget(textField));
        final inputSizingMetrics = <String, Object?>{
          'probeGlyph': 'x',
          'fontFamily': textField.textStyle.fontFamily,
          'fontSize': textField.textStyle.fontSize,
          'fontWeight': textField.textStyle.fontWeight?.value,
          'textScalerAtFontSize': MediaQuery.textScalerOf(
            inputElement,
          ).scale(textField.textStyle.fontSize ?? 16),
          'preferredCharacterCount': textField.field.size,
          'glyphAdvance': inputGlyphPainter.width,
          'effectiveAverageCharacterWidth': inputAverageCharacterWidth,
          'lineMetrics': {
            'width': inputGlyphLine.width,
            'ascent': inputGlyphLine.ascent,
            'unscaledAscent': inputGlyphLine.unscaledAscent,
            'descent': inputGlyphLine.descent,
            'height': inputGlyphLine.height,
          },
          'maximumCharacterWidthUsed': inputMaximumCharacterWidth,
          'intrinsicContentWidth': inputIntrinsicContentWidth,
          'horizontalPadding': {'left': 2, 'right': 2, 'total': 4},
          'horizontalBorder': {'left': 2, 'right': 2, 'total': 4},
          'borderBoxWidthFromFormula': inputIntrinsicContentWidth + 8,
          'actualBorderBox': _rectMap(inputBorderBox),
          'actualMinusFormulaWidth':
              inputBorderBox.width - inputIntrinsicContentWidth - 8,
        };
        inputGlyphPainter.dispose();

        final pngPath =
            'build/parity/html-document-native-${brightness.name}-${width.toInt()}.png';
        final jsonPath =
            'build/parity/html-document-native-${brightness.name}-${width.toInt()}.json';
        final measuredBodyRect = _rectMap(tester.getRect(bodyFinder));
        final viewportRect = _rectMap(
          tester.getRect(find.byType(NativeFetchedDocumentView)),
        );
        final textBoxes = <String, Object?>{
          'heading': heading.toJson(),
          'paragraph': paragraph.toJson(),
          'anchor': anchor.toJson(),
          'buttonLabel': buttonLabel.toJson(),
        };
        final controls = <String, Object?>{
          'input': {
            'borderBox': _rectMap(tester.getRect(find.byWidget(textField))),
            'fontFamily': textField.textStyle.fontFamily,
            'fontSize': textField.textStyle.fontSize,
            'colorArgb': textField.textStyle.color?.toARGB32(),
          },
          'button': {
            'borderBox': _rectMap(tester.getRect(find.byWidget(button))),
            'fontFamily': buttonLabel.style.fontFamily,
            'fontSize': buttonLabel.style.fontSize,
            'colorArgb': buttonLabel.style.color?.toARGB32(),
          },
        };
        late Map<String, int> canvasWhitePixel;
        markStep('capture-runAsync-start');
        await tester.runAsync(() async {
          markStep('to-image-start');
          final image =
              await (boundaryKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          markStep('to-image-complete');
          try {
            expect(image.width, width.toInt());
            expect(image.height, 844);
            markStep('png-byte-data-start');
            final pngBytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            markStep('png-byte-data-complete');
            final rgba = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            markStep('rgba-byte-data-complete');
            final pixelOffset =
                ((image.height - 1) * image.width + image.width - 1) * 4;
            canvasWhitePixel = {
              'x': image.width - 1,
              'y': image.height - 1,
              'r': rgba!.getUint8(pixelOffset),
              'g': rgba.getUint8(pixelOffset + 1),
              'b': rgba.getUint8(pixelOffset + 2),
              'a': rgba.getUint8(pixelOffset + 3),
            };
            final capture = <String, Object?>{
              'fixture': fixture['id'],
              'reference': fixture['webRevision'],
              'responseUrl': responseUrl,
              'mimeType': 'text/html',
              'status': 200,
              'width': width.toInt(),
              'height': 844,
              'devicePixelRatio': 1,
              'colorScheme': brightness.name,
              'bodyRectSource':
                  'HtmlWidget root-fragment render bounds; not a DOM body box.',
              'bodyRect': measuredBodyRect,
              'viewportRect': viewportRect,
              'textBoxes': textBoxes,
              'controls': controls,
              'inputSizingMetrics': inputSizingMetrics,
              'canvasWhitePixel': canvasWhitePixel,
              'pngPath': pngPath,
              'hostFontAliases': hostFontAliases,
              'diagnosticSteps': List<String>.of(diagnosticSteps),
              'fontLimits': [
                'PingFang TC Regular and Semibold host faces plus Arial are comparison-only inputs; extracted font data is ignored build output and is not bundled in the app.',
                'The fixture contains Latin text only; non-Latin fallback and glyph coverage are not measured.',
                'The PingFang TC aliases reproduce the local Chrome face selection on this host; they are not a portable Android font reference.',
                'This is a 1x capture at 390px or 768px; there is no 2x web reference.',
              ],
            };
            final pngFile = File(pngPath);
            markStep('png-write-start');
            await pngFile.parent.create(recursive: true);
            await pngFile.writeAsBytes(pngBytes!.buffer.asUint8List());
            markStep('png-write-complete');
            final jsonFile = File(jsonPath);
            markStep('json-write-start');
            await jsonFile.writeAsString(
              '${const JsonEncoder.withIndent('  ').convert(capture)}\n',
            );
            markStep('json-write-complete');
          } finally {
            markStep('image-dispose-start');
            image.dispose();
            markStep('image-dispose-complete');
          }
        });
        markStep('capture-runAsync-complete');
        expect(canvasWhitePixel['r'], 255);
        expect(canvasWhitePixel['g'], 255);
        expect(canvasWhitePixel['b'], 255);
        _expectFontSize(paragraph.style.fontSize, 16, 'body paragraph');
        _expectFontSize(
          textField.textStyle.fontSize,
          13.333333333333334,
          'input',
        );
        _expectFontSize(
          buttonLabel.style.fontSize,
          13.333333333333334,
          'button',
        );
        markStep('explicit-cleanup-start');
        await cleanup();
        markStep('test-body-complete');
      });
    }
  }
}
