/// Fetched documents and the script runtime side of the renderer (tier 3 in
/// plans/client.md): Canvas drawing and pointer input, computed-style export,
/// the dialog top layer, script callbacks and script form submission.
///
/// Install [NativeDocumentRuntime] as `RenderHost.documentRuntime` where
/// fetched documents are shown. Chat content does not import this library.
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_render/src/document_canvas_layout.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';

import 'src/document_canvas.dart';
import 'src/document_canvas_pointer.dart';
import 'src/document_top_layer.dart';
import 'src/html_script_callbacks.dart';
import 'src/html_script_submission.dart' as script;

export 'src/canvas_text_fonts.dart';
export 'src/document_canvas.dart';
export 'src/document_canvas_pointer.dart';
export 'src/document_computed_styles.dart';
export 'src/document_download.dart';
export 'src/document_top_layer.dart';
export 'src/html_script_callbacks.dart';
export 'src/html_script_submission.dart';
export 'src/scripts_platform.dart';

/// The native implementation of [DocumentRuntime].
class NativeDocumentRuntime implements DocumentRuntime {
  const NativeDocumentRuntime();

  @override
  Widget buildCanvas({
    required RenderCanvasSnapshot? snapshot,
    required double width,
    required double height,
    required bool cssWidthSpecified,
    required bool cssHeightSpecified,
    required Map<String, ui.Image> images,
  }) => NativeDocumentCanvas(
    images: images,
    cssWidthSpecified: cssWidthSpecified,
    cssHeightSpecified: cssHeightSpecified,
    snapshot: snapshot is NativeDocumentCanvasSnapshot
        ? snapshot
        : NativeDocumentCanvasSnapshot.fromJson({
            'id': 'static-canvas',
            'width': width,
            'height': height,
            'revision': 0,
            'commands': const [],
          }),
  );

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
  }) => NativeDocumentCanvasPointer(
    key: key,
    documentIdentity: documentIdentity,
    elementId: elementId,
    touchActionNone: touchActionNone,
    viewportOrigin: viewportOrigin,
    onEvent: onEvent,
    onTouchClickQueued: onTouchClickQueued,
    child: child,
  );

  @override
  DocumentTopLayer get topLayer => const NativeDocumentTopLayer();

  @override
  DocumentScriptCallbacks get scriptCallbacks =>
      const NativeDocumentScriptCallbacks();

  @override
  NativeHtmlFormSubmission decodeScriptFormSubmission(
    Map<String, dynamic> action, {
    required NativeHtmlFile? Function(
      String controlId,
      String resetVersion,
      int index,
    )
    resolveFile,
  }) => script.decodeScriptFormSubmission(action, resolveFile: resolveFile);
}
