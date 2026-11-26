import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;

import 'dart:ui' as ui;

import 'document_canvas_layout.dart';
import 'html_file.dart';
import 'html_form_submission.dart';
import 'html_media_spec.dart';

/// Services the renderer needs from the app that hosts it.
///
/// The renderer never talks to the Gateway or to platform code itself. It asks
/// its host for the document it is shown in, for image bytes, for media players
/// and for file selection. A host installs one [RenderHost] as
/// [RenderHost.fallback] at startup, or places a [RenderHostScope] above a
/// subtree. Without a host, documents are standalone: no document scope, no
/// fetched images, no media and no file selection.
class RenderHost {
  const RenderHost({
    this.documentScopeOf,
    this.mediaBuilder,
    this.filePickerFor,
    this.documentRuntime,
  });

  /// The fetched document that [context] belongs to, if any. Implementations
  /// should depend on an inherited widget so [context] rebuilds when it changes.
  final RenderDocumentScope? Function(BuildContext context)? documentScopeOf;

  /// Builds the player for an HTML `<audio>`/`<video>` element. [scope] is
  /// null for chat content (a message or a tool result), whose media must
  /// load only after the user taps it. Returning null shows no player.
  final RenderMediaBuilder? mediaBuilder;

  /// Returns a file picker for an `<input type=file>` in [scope]. The picker
  /// returns nothing once [isCurrent] turns false.
  final NativeHtmlFilePicker Function(
    RenderDocumentScope scope, {
    bool Function()? isCurrent,
  })?
  filePickerFor;

  /// Script-driven document features (tier 3). Chat content has none: its
  /// canvases stay blank and script form submissions are refused.
  final DocumentRuntime? documentRuntime;

  /// The host used where no [RenderHostScope] is in the tree.
  static RenderHost fallback = const RenderHost();

  static RenderHost of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RenderHostScope>()?.host ??
      fallback;

  RenderDocumentScope? documentScope(BuildContext context) =>
      documentScopeOf?.call(context);
}

typedef RenderMediaBuilder =
    Widget? Function(
      RenderDocumentScope? scope,
      NativeHtmlMediaSpec spec,
      Map<String, String> styles, {
      String? baseUrl,
      Object? accountIdentity,
    });

/// Places [host] above [child].
class RenderHostScope extends InheritedWidget {
  const RenderHostScope({super.key, required this.host, required super.child});
  final RenderHost host;
  @override
  bool updateShouldNotify(RenderHostScope oldWidget) =>
      !identical(host, oldWidget.host);
}

/// The fetched document a piece of HTML is shown in, as the renderer sees it.
///
/// Identity checks compare these objects with `identical`, so hosts must keep
/// one object per window and per loaded document.
abstract interface class RenderDocumentScope {
  RenderDocumentWindows get windows;
  RenderDocumentWindow? get window;
  String? get documentUrl;

  /// The account the document was loaded for. Work started for one account
  /// is dropped when this changes.
  Object get accountIdentity;
}

/// All document windows of one connection.
abstract interface class RenderDocumentWindows {
  bool get disposed;
  Object get accountIdentity;

  /// Changes whenever the selected window changes.
  int get selectionRevision;
  RenderDocumentWindow? get active;

  /// Loads images referenced by documents of this connection.
  RenderImageFetcher get imageFetcher;
}

abstract interface class RenderDocumentWindow {
  bool get disposed;
  bool get closing;
  RenderFetchedDocument? get currentDocument;
}

abstract interface class RenderFetchedDocument {
  String get url;

  /// The base URL for relative references (`<base href>` or [url]).
  String get effectiveBase;
}

/// Fetches image bytes on behalf of a document (CSS backgrounds).
abstract interface class RenderImageFetcher {
  Future<RenderFetchedImage> fetchImage(
    Uri source, {
    String? baseUrl,
    String? documentUrl,
  });
}

class RenderFetchedImage {
  const RenderFetchedImage(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

/// The script runtime side of fetched documents (tier 3 in plans/client.md):
/// Canvas drawing and pointer input, and form submissions made by scripts.
///
/// Implemented by `pirc_render_document`; this package only calls it.
abstract interface class DocumentRuntime {
  /// Paints [snapshot] (or a blank bitmap of [width] × [height]).
  Widget buildCanvas({
    required RenderCanvasSnapshot? snapshot,
    required double width,
    required double height,
    required bool cssWidthSpecified,
    required bool cssHeightSpecified,
    required Map<String, ui.Image> images,
  });

  /// Sends pointer input on [child] to the script of [documentIdentity].
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
  });

  /// The top layer of script-driven documents (modal dialogs). Chat content
  /// has none: a dialog there stays in normal flow.
  DocumentTopLayer get topLayer;

  /// The wire format between script callbacks and the document script.
  DocumentScriptCallbacks get scriptCallbacks;

  /// Decodes a form submission requested by a document script.
  NativeHtmlFormSubmission decodeScriptFormSubmission(
    Map<String, dynamic> action, {
    required NativeHtmlFile? Function(
      String controlId,
      String resetVersion,
      int index,
    )
    resolveFile,
  });
}

/// The top layer of a script-driven document: dialogs that a document script
/// opened with `showModal()`. Only the script runtime may put an element there;
/// markup alone never does.
abstract interface class DocumentTopLayer {
  /// The order of [element] in the top layer, or null when it is not in it.
  int? orderOf(dom.Element element);

  /// Wraps the content of a top-layer element, so focus stays inside it.
  Widget scope(Widget child);
}

/// The wire format of the callbacks between a rendered document and its
/// script: picked files, and the order in which queued script actions apply.
abstract interface class DocumentScriptCallbacks {
  /// The actions in [actions] whose `sequence` is newer than [lastConsumed].
  List<Map<String, dynamic>> pendingActions(
    List<Map<String, dynamic>> actions,
    int lastConsumed,
  );

  /// Sorts focus actions by `sequence`, then by `actionOrder`.
  void sortFocusActions(List<Map<String, dynamic>> actions);

  /// Encodes [files] for the script. File bytes are sent while their total
  /// fits in [budget]; returns the encoded files and the budget left.
  (List<Map<String, dynamic>>, int) encodeFiles(
    Iterable<NativeHtmlFile> files,
    int budget,
  );

  /// Reads a file-picker request the script queued.
  DocumentScriptFilePick decodeFilePick(Map<String, dynamic> action);
}

/// A file chooser a document script opened (`input.click()` or
/// `showPicker()`).
class DocumentScriptFilePick {
  const DocumentScriptFilePick({
    required this.id,
    required this.controlId,
    required this.resetVersion,
    required this.request,
  });
  final int id;
  final String controlId;
  final String resetVersion;
  final NativeHtmlFilePickerRequest request;
}
