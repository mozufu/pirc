import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_style_loading.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_text_fields.dart';

import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

Map<String, Object?> _rectMap(ui.Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};

String _normalizedText(String value) =>
    value.replaceAll('\uFFFC', '').replaceAll(RegExp(r'\s+'), ' ').trim();

({String text, List<int> starts, List<int> ends}) _normalizedTextWithOffsets(
  String value,
) {
  final text = StringBuffer();
  final starts = <int>[];
  final ends = <int>[];
  var index = 0;
  while (index < value.length) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit == 0xfffc) {
      index++;
      continue;
    }
    if (RegExp(r'\s').hasMatch(value.substring(index, index + 1))) {
      final start = index;
      while (index < value.length) {
        final next = value.codeUnitAt(index);
        if (next == 0xfffc) {
          index++;
        } else if (RegExp(r'\s').hasMatch(value.substring(index, index + 1))) {
          index++;
        } else {
          break;
        }
      }
      if (text.isNotEmpty && index < value.length) {
        text.write(' ');
        starts.add(start);
        ends.add(index);
      }
      continue;
    }
    text.write(value.substring(index, index + 1));
    starts.add(index);
    ends.add(index + 1);
    index++;
  }
  return (text: text.toString(), starts: starts, ends: ends);
}

TextStyle _textStyleAtOffset(InlineSpan span, int offset, TextStyle inherited) {
  if (span is! TextSpan) return inherited;
  final style = span.style == null ? inherited : inherited.merge(span.style);
  final localTextLength = span.text?.length ?? 0;
  if (offset < localTextLength || span.children == null) return style;
  var childOffset = offset - localTextLength;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final childLength = child.toPlainText().length;
    if (childOffset < childLength) {
      return _textStyleAtOffset(child, childOffset, style);
    }
    childOffset -= childLength;
  }
  return style;
}

ui.Rect _unionTextBoxes(List<ui.Rect> boxes) {
  var result = boxes.first;
  for (final box in boxes.skip(1)) {
    result = result.expandToInclude(box);
  }
  return result;
}

class _RichTextCapture {
  const _RichTextCapture({
    required this.text,
    required this.richTextText,
    required this.normalizedRichTextText,
    required this.rect,
    required this.richTextRect,
    required this.selectionStart,
    required this.selectionEnd,
    required this.selectionBoxes,
    required this.style,
  });

  final String text;
  final String richTextText;
  final String normalizedRichTextText;
  final ui.Rect rect;
  final ui.Rect richTextRect;
  final int selectionStart;
  final int selectionEnd;
  final List<ui.Rect> selectionBoxes;
  final TextStyle style;

  Map<String, Object?> toJson() => {
    'text': text,
    'richTextText': richTextText,
    'normalizedRichTextText': normalizedRichTextText,
    'selectionRangeRawCodeUnits': {
      'start': selectionStart,
      'end': selectionEnd,
    },
    'selectionBoxes': [for (final box in selectionBoxes) _rectMap(box)],
    'rect': _rectMap(rect),
    'richTextRect': _rectMap(richTextRect),
    'geometrySource':
        'Global viewport bounds from RenderParagraph.getBoxesForSelection TextBoxes transformed with localToGlobal for this text range; this selected-text glyph bound is not a CSS DOMRect.',
    'fontFamily': style.fontFamily,
    'fontFamilyFallback': style.fontFamilyFallback,
    'fontSize': style.fontSize,
    'fontWeight': style.fontWeight?.value,
    'fontStyle': style.fontStyle?.name,
    'lineHeightFactor': style.height,
    'letterSpacing': style.letterSpacing,
    'colorArgb': style.color?.toARGB32(),
    'decoration': style.decoration?.toString(),
  };
}

List<_RichTextCapture> _richTextCaptures(WidgetTester tester, String text) {
  final candidates = <_RichTextCapture>[];
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    final rawText = widget.text.toPlainText();
    final normalized = _normalizedTextWithOffsets(rawText);
    final matchStart = normalized.text.indexOf(text);
    if (matchStart < 0 || text.isEmpty) continue;
    final matchEnd = matchStart + text.length;
    final rawStart = normalized.starts[matchStart];
    final rawEnd = normalized.ends[matchEnd - 1];
    final finder = find.byWidget(widget);
    final inherited = DefaultTextStyle.of(tester.element(finder)).style;
    final renderParagraph = tester.renderObject<RenderParagraph>(finder);
    final localSelectionBoxes = renderParagraph.getBoxesForSelection(
      TextSelection(baseOffset: rawStart, extentOffset: rawEnd),
    );
    if (localSelectionBoxes.isEmpty) continue;
    final selectionBoxes = [
      for (final box in localSelectionBoxes)
        () {
          final localRect = box.toRect();
          return ui.Rect.fromPoints(
            renderParagraph.localToGlobal(localRect.topLeft),
            renderParagraph.localToGlobal(localRect.bottomRight),
          );
        }(),
    ];
    candidates.add(
      _RichTextCapture(
        text: text,
        richTextText: rawText,
        normalizedRichTextText: normalized.text,
        rect: _unionTextBoxes(selectionBoxes),
        richTextRect: tester.getRect(finder),
        selectionStart: rawStart,
        selectionEnd: rawEnd,
        selectionBoxes: selectionBoxes,
        style: _textStyleAtOffset(widget.text, rawStart, inherited),
      ),
    );
  }
  final exactTextCandidates = candidates
      .where((capture) => capture.normalizedRichTextText == text)
      .toList();
  final captures = exactTextCandidates.isNotEmpty
      ? exactTextCandidates
      : candidates;
  if (captures.isNotEmpty && exactTextCandidates.isEmpty) {
    final shortestMatchLength = captures
        .map((capture) => capture.normalizedRichTextText.length)
        .reduce((first, second) => first < second ? first : second);
    captures.removeWhere(
      (capture) => capture.normalizedRichTextText.length != shortestMatchLength,
    );
  }
  captures.sort((a, b) => a.rect.top.compareTo(b.rect.top));
  return captures;
}

Map<String, Object?> _styleDiagnosticsJson(NativeDocumentStylesResult result) =>
    {
      'imports': [
        for (final item in result.imports)
          {
            'href': item.href,
            'url': item.url,
            'baseUrl': item.baseUrl,
            'media': item.media,
            'supported': item.supported,
            'sourceOrder': item.sourceOrder,
            'sourceIndex': item.sourceIndex,
            'reason': item.reason,
          },
      ],
      'diagnostics': [
        for (final item in result.diagnostics)
          {
            'code': item.code,
            'message': item.message,
            'baseUrl': item.baseUrl,
            'selector': item.selector,
            'property': item.property,
          },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-document-styles.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final web =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-document-styles-expected.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  if (fixture['webRevision'] != 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c' ||
      web['reference'] != fixture['webRevision'] ||
      web['fixture'] != fixture['id']) {
    throw StateError(
      'HTML document style capture is not pinned to its Chrome fixture.',
    );
  }

  final responseHtml = fixture['responseHtml'] as String;
  final responseUrl =
      '${web['origin']}${fixture['responsePath']}?via=markdown-form';
  final responseBytes = Uint8List.fromList(utf8.encode(responseHtml));
  final styleSources = (fixture['stylesheets'] as Map<String, dynamic>);
  final snapshotNodes = (fixture['snapshotNodes'] as Map<String, dynamic>).map(
    (key, value) => MapEntry(key, '$value'),
  );
  final parsedResponse = html_parser.parse(responseHtml);
  final probeTexts = <String, String>{};
  for (final entry in snapshotNodes.entries) {
    if (const {'html', 'body', 'main', 'input'}.contains(entry.key)) continue;
    final element = parsedResponse.querySelector(entry.value);
    final text = _normalizedText(element?.text ?? '');
    if (text.isNotEmpty) probeTexts[entry.key] = text;
  }

  for (final width in [390.0, 768.0]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('native raw HTML CSS response ${width.toInt()} ${brightness.name}', (
        tester,
      ) async {
        final diagnosticSteps = <String>[];
        void markStep(String step) {
          diagnosticSteps.add(step);
          debugPrint('HTML styles capture step: $step');
        }

        late List<String> sansSerifFontFiles;
        markStep('font-load-start');
        await tester.runAsync(() async {
          await loadParityFonts();
          const supplemental = '/System/Library/Fonts/Supplemental/';
          sansSerifFontFiles = [
            '${supplemental}Arial.ttf',
            '${supplemental}Arial Bold.ttf',
            '${supplemental}Arial Italic.ttf',
            '${supplemental}Arial Bold Italic.ttf',
          ].where((path) => File(path).existsSync()).toList();
          if (sansSerifFontFiles.isEmpty) {
            throw StateError(
              'No host Arial files are available for sans-serif.',
            );
          }
          final loader = FontLoader('sans-serif');
          for (final path in sansSerifFontFiles) {
            loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
          }
          await loader.load();
        });
        markStep('font-load-complete');
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = ui.Size(width, 844);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

        final stylesheetLoads = <Map<String, Object?>>[];
        final loader = NativeDocumentStyleLoader(
          fetch: (reference, baseUrl) async {
            final path = Uri.parse(reference).path;
            final cssText = styleSources[path];
            if (cssText == null) {
              throw StateError(
                'No local CSS fixture for $reference from $baseUrl',
              );
            }
            stylesheetLoads.add({
              'url': reference,
              'baseUrl': baseUrl,
              'status': 200,
              'mimeType': 'text/css',
            });
            return <String, dynamic>{
              'status': 200,
              'mimeType': 'text/css',
              'charset': 'utf-8',
              'bytes': Uint8List.fromList(utf8.encode('$cssText')),
              'finalUrl': reference,
            };
          },
          resolve: (reference, baseUrl) async =>
              resolveNativeDocumentUrl(reference, baseUrl),
          isCurrent: () => true,
        );
        markStep('stylesheet-loader-start');
        final loaded = await loader.load(
          responseHtml,
          baseUrl: responseUrl,
          documentEncoding: 'utf-8',
        );
        markStep('stylesheet-loader-complete');
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
          stylesheets: loaded.stylesheets,
          styleDiagnostics: loaded.diagnostics,
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
        final viewportBoundary = GlobalKey();
        markStep('pump-widget-start');
        await tester.pumpWidget(
          RepaintBoundary(
            key: viewportBoundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.build(brightness),
              home: Material(
                type: MaterialType.transparency,
                child: NativeFetchedDocumentView(
                  document: document,
                  gateway: Gateway(),
                  onLink: (_) {},
                  onSubmit: (_) {},
                ),
              ),
            ),
          ),
        );
        markStep('pump-widget-complete');
        await tester.pumpAndSettle();
        markStep('pump-and-settle-complete');
        expect(tester.takeException(), isNull);

        final htmlWidgetFinder = find.byType(HtmlWidget);
        final inputWidget = tester
            .widgetList<NativeHtmlTextFieldWidget>(
              find.byType(NativeHtmlTextFieldWidget),
            )
            .singleWhere((widget) => widget.field.initialValue == 'input');
        final buttonWidget = tester
            .widgetList<NativeHtmlButtonWidget>(
              find.byType(NativeHtmlButtonWidget),
            )
            .singleWhere((widget) => widget.button.label == 'Button');
        expect(htmlWidgetFinder, findsOneWidget);
        expect(
          tester.getRect(find.byType(NativeFetchedDocumentView)).size,
          ui.Size(width, 844),
        );

        final richTextProbes = <String, Object?>{};
        for (final entry in probeTexts.entries) {
          final captures = _richTextCaptures(tester, entry.value);
          richTextProbes[entry.key] = captures.isEmpty
              ? {
                  'found': false,
                  'text': entry.value,
                  'reason':
                      'No visible RenderParagraph exposed a selection box for this normalized text range.',
                }
              : {
                  'found': true,
                  'text': entry.value,
                  'matches': [for (final capture in captures) capture.toJson()],
                };
        }

        final inputRect = tester.getRect(find.byWidget(inputWidget));
        final editableFinder = find
            .descendant(
              of: find.byWidget(inputWidget),
              matching: find.byType(EditableText),
            )
            .first;
        final editableRect = tester.getRect(editableFinder);
        final buttonRect = tester.getRect(find.byWidget(buttonWidget));
        final buttonLabel = _richTextCaptures(tester, 'Button');
        final inputInsets = {
          'left': editableRect.left - inputRect.left,
          'right': inputRect.right - editableRect.right,
          'top': editableRect.top - inputRect.top,
          'bottom': inputRect.bottom - editableRect.bottom,
        };
        final buttonLabelInsets = buttonLabel.isEmpty
            ? null
            : {
                'left': buttonLabel.first.rect.left - buttonRect.left,
                'right': buttonRect.right - buttonLabel.first.rect.right,
                'top': buttonLabel.first.rect.top - buttonRect.top,
                'bottom': buttonRect.bottom - buttonLabel.first.rect.bottom,
              };
        final nativeProbeMeasurements = <String, Object?>{};
        for (final entry in snapshotNodes.entries) {
          switch (entry.key) {
            case 'html':
              nativeProbeMeasurements[entry.key] = {
                'measurable': false,
                'reason':
                    'A separate html element render box is not exposed by NativeFetchedDocumentView.',
              };
              break;
            case 'body':
              nativeProbeMeasurements[entry.key] = {
                'measurable': true,
                'geometrySource':
                    'HtmlWidget root fragment bounds; not a DOM body box.',
                'rect': _rectMap(tester.getRect(htmlWidgetFinder)),
              };
              break;
            case 'main':
              nativeProbeMeasurements[entry.key] = {
                'measurable': false,
                'reason':
                    'main has no separate native render-box finder; the fragment box is recorded for body.',
              };
              break;
            case 'input':
              nativeProbeMeasurements[entry.key] = {
                'measurable': true,
                'geometrySource': 'NativeHtmlTextFieldWidget outer border box.',
                'rect': _rectMap(inputRect),
                'contentInsets': inputInsets,
                'fontFamily': inputWidget.textStyle.fontFamily,
                'fontSize': inputWidget.textStyle.fontSize,
                'fontWeight': inputWidget.textStyle.fontWeight?.value,
                'colorArgb': inputWidget.textStyle.color?.toARGB32(),
              };
              break;
            case 'button':
              nativeProbeMeasurements[entry.key] = {
                'measurable': true,
                'geometrySource':
                    'NativeHtmlButtonWidget outer box and visible RichText label.',
                'rect': _rectMap(buttonRect),
                'labelInsets': buttonLabelInsets,
                'labelRichText': buttonLabel.isEmpty
                    ? null
                    : buttonLabel.first.toJson(),
              };
              break;
            default:
              final captured = richTextProbes[entry.key];
              nativeProbeMeasurements[entry.key] = captured;
          }
        }

        final diagnosticDocument = html_parser.parse(content.text);
        final cascade = NativeDocumentStyleEngine(
          stylesheets: loaded.stylesheets,
          viewportWidth: width,
          dark: brightness == Brightness.dark,
        ).apply(diagnosticDocument);
        final viewRect = tester.getRect(find.byType(NativeFetchedDocumentView));
        final htmlWidgetRect = tester.getRect(htmlWidgetFinder);
        final stylesheetRecords = [
          for (var index = 0; index < loaded.stylesheets.length; index++)
            {
              'order': index,
              'baseUrl': loaded.stylesheets[index].baseUrl,
              'media': loaded.stylesheets[index].media,
              'cssText': loaded.stylesheets[index].cssText,
            },
        ];
        final pngPath =
            'build/parity/html-document-styles-native-${brightness.name}-${width.toInt()}.png';
        final jsonPath =
            'build/parity/html-document-styles-native-${brightness.name}-${width.toInt()}.json';
        late Map<String, int> viewportCornerPixel;
        markStep('capture-runAsync-start');
        await tester.runAsync(() async {
          markStep('to-image-start');
          final image =
              await (viewportBoundary.currentContext!.findRenderObject()
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
            viewportCornerPixel = {
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
              'viewportRect': _rectMap(viewRect),
              'htmlWidgetRootFragmentRect': _rectMap(htmlWidgetRect),
              'htmlWidgetRootFragmentRectNote':
                  'This root-fragment box is not a DOM body or main element box.',
              'probeMeasurements': nativeProbeMeasurements,
              'richTextProbes': richTextProbes,
              'controls': {
                'input': {
                  'outerBorderBox': _rectMap(inputRect),
                  'editableTextRect': _rectMap(editableRect),
                  'contentInsets': inputInsets,
                  'fontFamily': inputWidget.textStyle.fontFamily,
                  'fontSize': inputWidget.textStyle.fontSize,
                  'fontWeight': inputWidget.textStyle.fontWeight?.value,
                  'colorArgb': inputWidget.textStyle.color?.toARGB32(),
                },
                'button': {
                  'outerWidgetBox': _rectMap(buttonRect),
                  'labelInsets': buttonLabelInsets,
                  'labelRichText': buttonLabel.isEmpty
                      ? null
                      : buttonLabel.first.toJson(),
                },
              },
              'loadedStylesheets': stylesheetRecords,
              'stylesheetRequests': stylesheetLoads,
              'styleLoaderDiagnostics': loaded.diagnostics,
              'cascadeImportsAndDiagnostics': _styleDiagnosticsJson(cascade),
              'unsupportedNotes': fixture['notes'],
              'viewportCornerPixel': viewportCornerPixel,
              'pngPath': pngPath,
              'diagnosticSteps': List<String>.of(diagnosticSteps),
              'fontLimits': [
                'Arial and sans-serif use these macOS host Arial files as comparison-only aliases: ${sansSerifFontFiles.join(', ')}. They are not bundled in the app.',
                'The fixture text is Latin only; non-Latin fallback and glyph coverage are not measured.',
                'The capture uses 1x device scale at 390px or 768px; the web oracle has no 2x reference.',
              ],
              'hostFontAliases': {
                'Arial': {
                  'comparisonOnly': true,
                  'resolvedFaceFamily': 'Arial',
                  'files': sansSerifFontFiles,
                },
                'sans-serif': {
                  'comparisonOnly': true,
                  'resolvedFaceFamily': 'Arial',
                  'files': sansSerifFontFiles,
                },
              },
              'richTextGeometrySemantics':
                  'Selected-text bounds come from RenderParagraph.getBoxesForSelection transformed with localToGlobal into viewport coordinates; they measure native glyph ranges and are not CSS DOMRects.',
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
        expect(viewportCornerPixel['a'], 255);
        markStep('explicit-cleanup-start');
        await cleanup();
        markStep('test-body-complete');
      });
    }
  }
}
