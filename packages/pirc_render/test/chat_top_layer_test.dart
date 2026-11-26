import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:pirc_render/src/document_absolute_position.dart';
import 'package:pirc_render/src/document_canvas_layout.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/render_host.dart';

import 'support/render_theme.dart';

/// Only the document runtime may put an element into the top layer. Chat
/// content has no runtime, so markup that carries the runtime's private
/// marker stays in normal flow (a safety check: it cannot cover the screen).
void main() {
  const markup =
      '<div style="position:relative;width:300px;height:200px">'
      '<dialog open data-pirc-dialog-modal="1" style="position:fixed;'
      'left:0;top:0;width:120px;height:40px;margin:0;padding:0">Hi</dialog>'
      '</div>';

  Future<void> pump(
    WidgetTester tester,
    DocumentRuntime? runtime, {
    Object? scriptDocument,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: renderTestTheme(),
      home: RenderHostScope(
        host: RenderHost(documentRuntime: runtime),
        child: Scaffold(
          body: NativeDocumentPositioningViewport(
            child: NativeHtmlDocument(
              nodes: [NativeHtmlRaw(markup)],
              style: const TextStyle(fontSize: 15),
              styles: MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              imageViewport: const Size(400, 600),
              scriptDocument: scriptDocument,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('chat content ignores a top-layer marker', (tester) async {
    final runtime = _Runtime();
    await pump(tester, null);
    await tester.pumpAndSettle();
    expect(find.text('Hi', findRichText: true), findsOneWidget);
    expect(find.byKey(_Runtime.marker), findsNothing);
    expect(runtime.asked, isEmpty);
  });

  testWidgets('an installed runtime does not reach chat content', (
    tester,
  ) async {
    final runtime = _Runtime();
    await pump(tester, runtime);
    await tester.pumpAndSettle();
    expect(find.text('Hi', findRichText: true), findsOneWidget);
    expect(find.byKey(_Runtime.marker), findsNothing);
    expect(runtime.asked, isEmpty);
  });

  test('the chat sanitizer drops the private marker', () {
    expect(
      sanitizeNativeHtml(markup),
      isNot(contains('data-pirc-dialog-modal')),
    );
    expect(
      sanitizeNativeHtml(markup, markdownPolicy: false),
      contains('data-pirc-dialog-modal'),
    );
  });

  testWidgets('the document runtime decides the top layer', (tester) async {
    final runtime = _Runtime();
    await pump(tester, runtime, scriptDocument: Object());
    await tester.pumpAndSettle();
    expect(find.text('Hi', findRichText: true), findsOneWidget);
    expect(runtime.asked, contains('dialog'));
    expect(find.byKey(_Runtime.marker), findsOneWidget);
  });
}

class _Runtime implements DocumentRuntime, DocumentTopLayer {
  static const marker = ValueKey('top-layer');
  final asked = <String>{};

  @override
  DocumentTopLayer get topLayer => this;

  @override
  int? orderOf(dom.Element element) {
    asked.add(element.localName!);
    final value = element.attributes['data-pirc-dialog-modal'];
    return value == null ? null : int.tryParse(value) ?? 0;
  }

  @override
  Widget scope(Widget child) => KeyedSubtree(key: marker, child: child);

  @override
  DocumentScriptCallbacks get scriptCallbacks => const _NoScript();

  @override
  Widget buildCanvas({
    required RenderCanvasSnapshot? snapshot,
    required double width,
    required double height,
    required bool cssWidthSpecified,
    required bool cssHeightSpecified,
    required Map<String, ui.Image> images,
  }) => const SizedBox();

  @override
  Widget canvasPointerSurface({
    Key? key,
    required Widget child,
    required Object documentIdentity,
    required String elementId,
    required bool touchActionNone,
    Offset Function()? viewportOrigin,
    required Future<bool> Function(String type, Map<String, dynamic> data)
    onEvent,
    VoidCallback? Function(Map<String, dynamic> data)? onTouchClickQueued,
  }) => child;

  @override
  NativeHtmlFormSubmission decodeScriptFormSubmission(
    Map<String, dynamic> action, {
    required NativeHtmlFile? Function(
      String controlId,
      String resetVersion,
      int index,
    )
    resolveFile,
  }) => throw UnimplementedError();
}

/// A document with no script: no queued actions, no picked files.
class _NoScript implements DocumentScriptCallbacks {
  const _NoScript();
  @override
  List<Map<String, dynamic>> pendingActions(
    List<Map<String, dynamic>> actions,
    int lastConsumed,
  ) => const [];
  @override
  void sortFocusActions(List<Map<String, dynamic>> actions) {}
  @override
  (List<Map<String, dynamic>>, int) encodeFiles(
    Iterable<NativeHtmlFile> files,
    int budget,
  ) => (const [], budget);
  @override
  DocumentScriptFilePick decodeFilePick(Map<String, dynamic> action) =>
      throw StateError('no script');
}
