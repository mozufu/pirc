import 'render_l10n.dart';
import 'document_object_urls.dart';
import 'package:csslib/visitor.dart' as css;
import 'package:csslib/parser.dart' as css_parser;
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'native_image_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'svg_dimensions.dart';
import 'document_canvas_layout.dart';
import 'document_html_image.dart';
import 'document_layout.dart';
import 'document_fragment.dart';
import 'document_computed_style_spec.dart';
import 'document_offsets.dart';
import 'document_relative_position.dart';
import 'document_transform.dart';
import 'document_absolute_position.dart';
import 'document_pointer_events.dart';
import 'document_pointer_style.dart';
import 'document_margin_collapse.dart';
import 'document_element_scroll.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;
import 'render_theme.dart';
import 'render_host.dart';
import 'document_background_image.dart';
import 'remote_content_gate.dart';
import 'html_media_spec.dart';
import 'html_background_gradient.dart';
import 'html_gradient_decoration.dart';
import 'html_image_background_decoration.dart';
import 'html_background_layers.dart';
import 'html_date.dart';
import 'html_file.dart';
import 'html_highlight_styles.dart';
import 'html_controls.dart';
import 'html_text_fields.dart';
import 'html_control_box_style.dart';
import 'html_document_grid.dart';
import 'html_document_flex.dart';
import 'html_document_box.dart';
import 'html_responsive_image.dart';
import 'native_image_density.dart';
import 'native_raster_images.dart';
import 'html_grid_template.dart';
import 'html_select.dart';
import 'html_details.dart';
import 'html_buttons.dart';
import 'html_range.dart';
import 'html_code_header.dart';
import 'html_fieldset.dart';
import 'html_control_baseline.dart';
import 'html_inline_intrinsic_overflow.dart';
import 'html_forms.dart';
import 'html_form_feedback.dart';
import 'html_form_submission.dart';
import 'html_history_controls.dart';
import 'html_document_controls.dart';
import 'html_policy.dart';
import 'html_named_properties.dart';
import 'html_syntax.dart';
import 'markdown_selection.dart';
import 'native_math_paragraph.dart';
import 'native_inline_math.dart';

export 'html_history_controls.dart';

typedef NativeHtmlMediaBuilder =
    Widget Function(NativeHtmlMediaSpec spec, Map<String, String> styles);

final _allowedUri = RegExp(
  r'^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))',
  caseSensitive: false,
);
final _uriWhitespace = RegExp(
  r'[\x00-\x20\x7f-\x9f\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]',
);

/// HTML is parsed into a DOM then constrained to the pinned web's declarative
/// policy. No JS, filesystem loader or browser is used. Namespace mutation,
/// named-property and browser-specific sanitizer differences stay in PARITY.md.
String sanitizeNativeHtml(String source, {bool markdownPolicy = true}) {
  final fragment = html.parseFragment(source);
  void clean(dom.Node parent) {
    for (final child in parent.nodes.toList()) {
      if (child is dom.Comment) {
        child.remove();
        continue;
      }
      if (child is! dom.Element) continue;
      final tag = child.localName!.toLowerCase();
      if (!nativeHtmlTags.contains(tag)) {
        if (nativeHtmlForbiddenContents.contains(tag)) {
          child.remove();
          continue;
        }
        clean(child);
        final index = parent.nodes.indexOf(child);
        parent.nodes.insertAll(index, child.nodes.toList());
        child.remove();
        continue;
      }
      for (final key in child.attributes.keys.toList()) {
        final name = '$key'.toLowerCase();
        if (markdownPolicy && name == 'data-pirc-dialog-modal') {
          // Only a document script may open a modal dialog; chat markup
          // cannot claim the top layer.
          child.attributes.remove(key);
          continue;
        }
        var value = child.attributes[key]!;
        // DOMPurify keeps value untouched and applies ECMAScript trim to
        // other attributes before validation (not Dart's broader trim set).
        if (markdownPolicy && name != 'value') {
          value = value.replaceAll(
            RegExp(
              r'^[\x09-\x0d \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|[\x09-\x0d \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
            ),
            '',
          );
          child.attributes[key] = value;
        }
        if (markdownPolicy && (name == 'id' || name == 'name')) {
          value = value.replaceAll(RegExp(r'^[\t\n\f\r ]+|[\t\n\f\r ]+$'), '');
          if (nativeHtmlBlockedNamedProperties.contains(value)) {
            child.attributes.remove(key);
            continue;
          }
          child.attributes[key] = value;
        }
        if (tag == 'a' &&
            name == 'href' &&
            RegExp(r'^file:', caseSensitive: false).hasMatch(value.trim())) {
          value = value.trim().replaceFirst(
            RegExp(r'^file:(//(localhost)?)?', caseSensitive: false),
            '',
          );
          child.attributes[key] = value.isEmpty ? '#' : value;
        }
        final rawSubmitterAttribute =
            !markdownPolicy &&
            const {'button', 'input'}.contains(tag) &&
            const {
              'formaction',
              'formmethod',
              'formenctype',
              'formtarget',
            }.contains(name);
        if (!rawSubmitterAttribute &&
            !nativeHtmlAttributes.contains(name) &&
            !name.startsWith('data-') &&
            !name.startsWith('aria-')) {
          child.attributes.remove(key);
          continue;
        }
        if ((rawSubmitterAttribute && name != 'formaction') ||
            nativeHtmlUriSafeAttributes.contains(name) ||
            (!markdownPolicy && name == 'srcset') ||
            name.startsWith('data-') ||
            name.startsWith('aria-')) {
          continue;
        }
        final uri = value.replaceAll(_uriWhitespace, '');
        final data =
            ['src', 'href', 'xlink:href'].contains(name) &&
            nativeHtmlDataTags.contains(tag) &&
            uri.startsWith('data:');
        final blob =
            uri.startsWith('blob:') &&
            ((name == 'src' &&
                    const {'img', 'audio', 'video', 'source'}.contains(tag)) ||
                (name == 'poster' && tag == 'video') ||
                (name == 'href' && tag == 'a'));
        if (uri.isNotEmpty && !_allowedUri.hasMatch(uri) && !data && !blob) {
          child.attributes.remove(key);
        }
      }
      clean(child);
    }
  }

  clean(fragment);
  return fragment.outerHtml;
}

class NativeHtmlDocument extends StatefulWidget {
  const NativeHtmlDocument({
    super.key,
    required this.nodes,
    required this.style,
    required this.styles,
    required this.builders,
    this.imageBuilder,
    this.mediaBuilder,
    this.checkboxBuilder,
    this.onLink,
    this.onFormSubmit,
    this.onScriptClick,
    this.onDetailsActivate,
    this.preserveControlValues = false,
    this.retainedControls,
    this.onScriptControlClick,
    this.scriptFilePickerActions = const [],
    this.takeScriptFilePickerActions,
    this.scriptFocusActions = const [],
    this.takeScriptFocusActions,
    this.onScriptFilePickerResult,
    this.scriptFilePickerIsCurrent,
    this.scriptFileSelections,
    this.scriptFormActions = const [],
    this.onScriptFormActionsConsumed,
    this.takeScriptFormActions,
    this.scriptSnapshot,
    this.onScriptRestoreControls,
    this.scriptDocument,
    this.canvases = const {},
    this.canvasImages = const {},
    this.vectorImageSources = const {},
    this.htmlImages = const {},
    this.deferImageLoading = false,
    this.onScriptEvent,
    this.onScriptDetailedEvent,
    this.onScriptTouchClickQueued,
    this.markdownStyles = true,
    this.onNavigate,
    this.viewport,
    this.fragmentIndex,
    this.authorStylesBuilder,
    this.imageViewport,
    this.imageDark,
    this.historyController,
    this.filePicker,
    this.layoutController,
    this.elementScrollController,
    this.layoutRevision = 0,
    this.layoutKnownIds = const {},
    this.layoutNoBoxIds = const {},
    this.layoutComputedStyles = const {},
    this.layoutOffsetSpecs = const {},
    this.documentTopMargins = const {},
    this.documentPercentTopMargins = const {},
  });
  final List<md.Node> nodes;
  final TextStyle style;
  final MarkdownStyleSheet styles;
  final Map<String, MarkdownElementBuilder> builders;
  final MarkdownImageBuilder? imageBuilder;
  final NativeHtmlMediaBuilder? mediaBuilder;
  final MarkdownCheckboxBuilder? checkboxBuilder;
  final void Function(String)? onLink;
  final ValueChanged<NativeHtmlFormSubmission>? onFormSubmit;
  final Future<bool> Function(String id, List<Map<String, dynamic>> controls)?
  onScriptClick;

  /// Ready script runtimes own checkable activation and checked state.
  final Future<bool> Function(String id, List<Map<String, dynamic>> controls)?
  onScriptControlClick;
  final List<Map<String, dynamic>> scriptFilePickerActions;
  final List<Map<String, dynamic>> Function(List<int>)?
  takeScriptFilePickerActions;
  final List<Map<String, dynamic>> scriptFocusActions;
  final List<Map<String, dynamic>> Function(List<int>)? takeScriptFocusActions;
  final Future<void> Function(
    int, {
    List<Map<String, dynamic>>? files,
    bool cancelled,
    String? error,
  })?
  onScriptFilePickerResult;
  final NativeHtmlScriptFileSelections? scriptFileSelections;
  final List<Map<String, dynamic>> scriptFormActions;
  final ValueChanged<List<int>>? onScriptFormActionsConsumed;
  final List<Map<String, dynamic>> Function(List<int>)? takeScriptFormActions;

  /// A new script snapshot owns its control values; do not restore old edits.
  final Object? scriptSnapshot;
  final Future<void> Function(List<Map<String, dynamic>>)?
  onScriptRestoreControls;
  final Object? scriptDocument;

  /// Captures document/account ownership independently of this renderer's life.
  /// Used only for an already-authorized chooser, never to start a hidden one.
  final bool Function()? scriptFilePickerIsCurrent;
  final ValueChanged<String>? onDetailsActivate;

  /// Static presentation updates retain live values; script snapshots stay authoritative.
  final bool preserveControlValues;
  final NativeHtmlDocumentControls? retainedControls;
  final Map<String, RenderCanvasSnapshot> canvases;
  final Map<String, ui.Image> canvasImages;
  final Map<String, Uint8List> vectorImageSources;
  final Map<String, NativeDocumentHtmlImage> htmlImages;
  final bool deferImageLoading;
  final Future<bool> Function(
    String id,
    String type,
    List<Map<String, dynamic>> controls, {
    String? submitter,
  })?
  onScriptEvent;
  final Future<bool> Function(
    String id,
    String type,
    List<Map<String, dynamic>> controls,
    Map<String, dynamic> eventData,
  )?
  onScriptDetailedEvent;

  /// Called synchronously when a primary touch click is queued for dispatch.
  /// The returned callback runs once after that click dispatch completes.
  final VoidCallback? Function(String id, Map<String, dynamic> data)?
  onScriptTouchClickQueued;
  final bool markdownStyles;

  /// The document viewport for responsive media and, in full-document mode,
  /// the initial CSS containing block. Omit it for content-sized HTML fragments.
  final Size? imageViewport;
  final bool? imageDark;
  final ValueChanged<NativeHtmlLink>? onNavigate;
  final NativeHtmlViewportController? viewport;
  final NativeDocumentFragmentIndex? fragmentIndex;
  final Map<String, String>? Function(dom.Element)? authorStylesBuilder;
  final NativeHtmlHistoryController? historyController;
  final NativeHtmlFilePicker? filePicker;
  final NativeDocumentLayoutController? layoutController;
  final NativeDocumentElementScrollController? elementScrollController;
  final int layoutRevision;
  final Set<String> layoutKnownIds, layoutNoBoxIds;
  final Map<String, NativeDocumentComputedStyleSpec> layoutComputedStyles;
  final Map<String, NativeDocumentOffsetSpec> layoutOffsetSpecs;
  final Map<String, double> documentTopMargins;
  final Map<String, NativeDocumentTopMarginGroup> documentPercentTopMargins;
  @override
  State<NativeHtmlDocument> createState() => _NativeHtmlDocumentState();
}

class _NativeHtmlDocumentState extends State<NativeHtmlDocument>
    implements NativeHtmlHistoryBinding {
  final nonce = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final slots = <String, md.Element>{};
  late String content;
  String? sanitizedContent;
  final _backgroundSvgCache = NativeSvgBackgroundCache();
  final _localElementScroll = NativeDocumentElementScrollController();
  NativeDocumentElementScrollController get _elementScroll =>
      widget.elementScrollController ?? _localElementScroll;
  final _canvasPointerKeys = <String, GlobalKey>{};
  Size? get _documentViewport {
    final viewport = widget.imageViewport;
    return !widget.markdownStyles &&
            viewport != null &&
            viewport.width.isFinite &&
            viewport.height.isFinite &&
            viewport.width >= 0 &&
            viewport.height >= 0
        ? viewport
        : null;
  }

  NativeHtmlControlState? controls;
  NativeHtmlTextFieldState? textFields;
  NativeHtmlSelectState? selects;
  NativeHtmlDetailsGroups? detailsGroups;
  NativeHtmlButtonState? buttons;
  NativeHtmlRangeState? ranges;
  NativeHtmlDateState? dates;
  NativeHtmlFileInputState? files;
  NativeHtmlDetachedControls? _parkedControls;
  bool _claimedRetainedControls = false;
  Object? _renderedScriptSnapshot;
  NativeHtmlForms? forms;
  NativeHtmlHistoryController? _attachedHistoryController;
  int _scriptSourceGeneration = 0;
  bool _scriptFilePickerScheduled = false, _scriptFilePickerRunning = false;
  bool _scriptFocusActionsScheduled = false, _applyingScriptFocus = false;
  bool _retiredScriptFocusNodeDisposalScheduled = false;
  int _lastConsumedScriptFocusSequence = 0;
  String? _lastNativeScriptFocusId;
  Set<String> _scriptFocusEchoControlIds = const {};
  final Map<String, FocusNode> _scriptFocusableNodes = {};
  final Set<FocusNode> _retiredScriptFocusableNodes = {};
  RenderDocumentScope? _nativeDocumentScope;

  /// Tier-3 services; null for chat content, where script callbacks and the
  /// top layer are inert.
  DocumentRuntime? _documentRuntime;

  /// [_documentRuntime] where this HTML is a document: inside a document
  /// scope or driven by a script. Chat HTML gets no top layer and no canvas
  /// even if a runtime is installed above it.
  DocumentRuntime? get _documentContextRuntime =>
      _nativeDocumentScope != null || widget.scriptDocument != null
      ? _documentRuntime
      : null;
  static const _scriptFileBytesBudget = 2 * 1024 * 1024;
  final _localScriptFileSelections = NativeHtmlScriptFileSelections();
  NativeHtmlScriptFileSelections get _scriptFileSelections =>
      widget.scriptFileSelections ?? _localScriptFileSelections;
  bool _scriptFormActionsScheduled = false;
  int _lastConsumedFormAction = 0;
  bool _suppressFocusReveal = false;
  int _focusRevealEpoch = 0;
  FocusNode? _focusRevealNode;
  bool Function()? _focusRevealIsCurrent;
  final Map<(String, String), List<NativeHtmlFile>> _submissionFiles = {};

  Object? _renderedScriptDocument;
  NativeHtmlControlSnapshot? _pendingScriptHistoryRestore;
  @override
  void initState() {
    super.initState();
    _elementScroll.beginDocument(widget.scriptDocument ?? this);
    final retained = widget.retainedControls?.take(this);
    if (retained != null) _restoreControlModels(retained);
    serialize(force: retained != null);
    FocusManager.instance.addListener(_handleNativeFocusChange);
    _scheduleScriptFilePickers();
    _scheduleScriptFormActions();
    _attachHistoryController(widget.historyController);
  }

  void _clearControlModels() {
    controls = null;
    textFields = null;
    selects = null;
    ranges = null;
    dates = null;
    files = null;
  }

  void _restoreControlModels(NativeHtmlDetachedControls value) {
    controls = value.controls;
    textFields = value.textFields;
    selects = value.selects;
    ranges = value.ranges;
    dates = value.dates;
    files = value.files;
    _renderedScriptDocument = widget.scriptDocument;
    _claimedRetainedControls = true;
    // A replaced HtmlWidget must not reparent its factory with retired bindings.
    widget.viewport?.resetContent();
  }

  void _parkControlModels(NativeHtmlDocumentControls? owner) {
    if (owner == null ||
        controls == null ||
        textFields == null ||
        selects == null ||
        ranges == null ||
        dates == null ||
        files == null) {
      return;
    }
    final snapshot = captureNativeHtmlHistory();
    final value = NativeHtmlDetachedControls(
      controls: controls!,
      textFields: textFields!,
      ranges: ranges!,
      selects: selects!,
      dates: dates!,
      files: files!,
    );
    if (!owner.retain(this, value)) return;
    forms?.dispose();
    forms = null;
    buttons?.invalidatePendingActivations();
    _parkedControls = value;
    _clearControlModels();
    _attachedHistoryController?.detach(this, snapshot: snapshot);
    _attachedHistoryController = null;
  }

  @override
  void deactivate() {
    _parkControlModels(widget.retainedControls);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (_parkedControls != null) {
      final value = widget.retainedControls?.take(this);
      _parkedControls = null;
      if (value != null) {
        _restoreControlModels(value);
      } else {
        _renderedScriptDocument = null;
      }
      serialize(force: true);
      _attachHistoryController(widget.historyController);
      setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = RenderHost.of(context);
    _nativeDocumentScope = host.documentScope(context);
    if (!identical(_documentRuntime, host.documentRuntime)) {
      _documentRuntime = host.documentRuntime;
      buttons?.updateOnClick(_scriptClickHandler);
      _bindScriptControls();
      _scheduleScriptFilePickers();
      _scheduleScriptFormActions();
    }
    _scheduleScriptFocusActions();
  }

  @override
  void didUpdateWidget(covariant NativeHtmlDocument old) {
    super.didUpdateWidget(old);
    var inheritedControls = false;
    final lifetimeChanged = old.retainedControls != widget.retainedControls;
    if (lifetimeChanged) {
      _parkControlModels(old.retainedControls);
      _parkedControls = null;
      final retained = widget.retainedControls?.take(this);
      if (retained != null) {
        forms?.dispose();
        forms = null;
        controls?.dispose();
        textFields?.dispose();
        selects?.dispose();
        ranges?.dispose();
        dates?.dispose();
        files?.dispose();
        _restoreControlModels(retained);
        inheritedControls = true;
      }
    }
    if (!identical(old.viewport, widget.viewport)) {
      old.viewport?._unbindFragments(this);
      old.viewport?._unbindFragmentFocus(this);
    }
    final documentChanged = old.scriptDocument != widget.scriptDocument;
    if (documentChanged ||
        old.elementScrollController != widget.elementScrollController) {
      _elementScroll.beginDocument(widget.scriptDocument ?? this);
    }
    if (documentChanged) {
      _pendingScriptHistoryRestore = null;
      _cancelFocusRevealSuppression();
      _canvasPointerKeys.clear();
      _lastNativeScriptFocusId = null;
      _retireAllScriptFocusableNodes();
      _lastConsumedScriptFocusSequence = 0;
      _lastConsumedFormAction = 0;
      _submissionFiles.clear();
      _localScriptFileSelections.clear();
    } else if (widget.scriptFormActions.isNotEmpty) {
      _captureSubmissionFiles();
    }
    final sourceChanged =
        old.nodes != widget.nodes ||
        documentChanged ||
        !identical(old.viewport, widget.viewport) ||
        !identical(old.fragmentIndex, widget.fragmentIndex);
    final historyChanged = old.historyController != widget.historyController;
    final carriedSnapshot =
        sourceChanged &&
            !documentChanged &&
            !historyChanged &&
            !widget.preserveControlValues &&
            widget.scriptSnapshot == null &&
            old.scriptSnapshot == widget.scriptSnapshot
        ? old.historyController?.capture()
        : null;
    if (sourceChanged || historyChanged || lifetimeChanged) {
      old.historyController?.detach(this);
      _attachedHistoryController = null;
      if (sourceChanged || inheritedControls || lifetimeChanged) {
        serialize(force: inheritedControls || lifetimeChanged);
      }
      _attachHistoryController(widget.historyController);
      if (carriedSnapshot != null && !carriedSnapshot.isEmpty) {
        widget.historyController?.restore(carriedSnapshot);
      }
    }
    if (old.onScriptClick != widget.onScriptClick ||
        old.onScriptEvent != widget.onScriptEvent) {
      buttons?.updateOnClick(_scriptClickHandler);
    }
    forms?.onSubmit = widget.onFormSubmit;
    final pendingHistory = _pendingScriptHistoryRestore;
    if (pendingHistory != null && widget.scriptSnapshot != null) {
      _pendingScriptHistoryRestore = null;
      restoreNativeHtmlHistory(pendingHistory);
    }
    _bindScriptControls();
    _scheduleScriptFilePickers();
    _scheduleScriptFocusActions();
    _scheduleScriptFormActions();
  }

  @override
  void dispose() {
    widget.viewport?._unbindFragments(this);
    widget.viewport?._unbindFragmentFocus(this);
    _localElementScroll.dispose();
    _backgroundSvgCache.clear();
    FocusManager.instance.removeListener(_handleNativeFocusChange);
    for (final focusNode in _scriptFocusableNodes.values) {
      focusNode.dispose();
    }
    _scriptFocusableNodes.clear();
    for (final focusNode in _retiredScriptFocusableNodes) {
      focusNode.dispose();
    }
    _retiredScriptFocusableNodes.clear();
    _attachedHistoryController?.detach(
      this,
      snapshot:
          widget.retainedControls == null &&
              widget.scriptSnapshot == null &&
              widget.onScriptEvent == null &&
              widget.onScriptClick == null
          ? captureNativeHtmlHistory()
          : null,
    );
    _attachedHistoryController = null;
    forms?.dispose();
    controls?.dispose();
    textFields?.dispose();
    selects?.dispose();
    detailsGroups?.dispose();
    buttons?.dispose();
    ranges?.dispose();
    dates?.dispose();
    files?.dispose();
    _submissionFiles.clear();
    _localScriptFileSelections.clear();
    super.dispose();
  }

  void _attachHistoryController(NativeHtmlHistoryController? controller) {
    _attachedHistoryController = controller;
    controller?.attach(this, retainedControls: _claimedRetainedControls);
    _claimedRetainedControls = false;
  }

  @override
  NativeHtmlControlSnapshot? captureNativeHtmlHistory() {
    final parked = _parkedControls;
    final available = parked != null && !parked.taken && !parked.isDisposed
        ? parked
        : null;
    final currentControls = controls ?? available?.controls;
    final currentTextFields = textFields ?? available?.textFields;
    final currentRanges = ranges ?? available?.ranges;
    final currentSelects = selects ?? available?.selects;
    final currentContent = content;
    if (currentControls == null ||
        currentTextFields == null ||
        currentRanges == null ||
        currentSelects == null) {
      return null;
    }
    return NativeHtmlHistoryControls.capture(
      scripted: widget.scriptSnapshot != null,
      htmlSource: currentContent,
      controls: currentControls,
      textFields: currentTextFields,
      ranges: currentRanges,
      selects: currentSelects,
      dates: dates ?? available?.dates,
    );
  }

  @override
  void restoreNativeHtmlHistory(NativeHtmlControlSnapshot snapshot) {
    final currentControls = controls;
    final currentTextFields = textFields;
    final currentRanges = ranges;
    final currentSelects = selects;
    final currentContent = content;
    if (currentControls == null ||
        currentTextFields == null ||
        currentRanges == null ||
        currentSelects == null) {
      return;
    }
    NativeHtmlHistoryControls.restore(
      htmlSource: currentContent,
      snapshot: snapshot,
      controls: currentControls,
      textFields: currentTextFields,
      ranges: currentRanges,
      selects: currentSelects,
      dates: dates,
    );
    if (widget.onScriptRestoreControls != null) {
      if (widget.scriptSnapshot == null) {
        // The initial declarative renderer precedes script IDs. Preserve this
        // snapshot until the first scripted DOM has attached its registries.
        _pendingScriptHistoryRestore = snapshot;
      } else {
        final document = widget.scriptDocument;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(widget.scriptDocument, document)) {
            unawaited(
              widget.onScriptRestoreControls?.call(_scriptControlValues()),
            );
          }
        });
      }
    }
  }

  void serialize({bool force = false}) {
    // Repainting the same script snapshot must retain live native edits without
    // round-tripping a stale history projection back into the running VM.
    final preserveValues =
        widget.preserveControlValues ||
        widget.scriptSnapshot != null &&
            identical(_renderedScriptSnapshot, widget.scriptSnapshot);
    slots.clear();
    String node(md.Node n) {
      if (n is NativeHtmlRaw) return n.html;
      if (n is md.Text) return const HtmlEscape().convert(n.text);
      if (n is! md.Element) return '';
      if (widget.builders.containsKey(n.tag) && n.tag.startsWith('pirc-')) {
        final id = '$nonce-${slots.length}';
        slots[id] = n;
        final block = widget.builders[n.tag]!.isBlockElement();
        final tag = block ? 'div' : 'span';
        return '<$tag data-pirc-native="$id"></$tag>';
      }
      final attrs = n.attributes.entries
          .where((e) => !e.key.startsWith('pirc-'))
          .map((e) => ' ${e.key}="${const HtmlEscape().convert(e.value)}"')
          .join();
      if (['br', 'hr', 'img', 'input'].contains(n.tag)) {
        final task = n.tag == 'input' && n.attributes['type'] == 'checkbox';
        return '<${n.tag}$attrs${task ? ' data-pirc-task="$nonce"${n.attributes.containsKey('disabled') ? '' : ' disabled=""'}' : ''}>';
      }
      return '<${n.tag}$attrs>${(n.children ?? []).map(node).join()}</${n.tag}>';
    }

    final sanitized = sanitizeNativeHtml(
      widget.nodes.map(node).join('\n'),
      markdownPolicy: widget.markdownStyles,
    );
    if (force ||
        sanitizedContent != sanitized ||
        _renderedScriptDocument != widget.scriptDocument) {
      if (sanitizedContent != null) {
        _scriptSourceGeneration++;
        buttons?.invalidatePendingActivations();
        // HtmlWidget keeps its factory for its entire State lifetime. Rebuild
        // it when annotation owners change, while keeping anchor navigation
        // pointed at the new widget rather than disposed control states.
        widget.viewport?.resetContent();
      }
      _backgroundSvgCache.clear();
      forms?.dispose();
      final previousControls = controls;
      final previousTextFields = textFields;
      final previousSelects = selects;
      detailsGroups?.dispose();
      final previousButtons = buttons;
      final previousRanges = ranges;
      final previousDates = dates;
      final previousFiles = files;
      if (_renderedScriptDocument != widget.scriptDocument) {
        _retireAllScriptFocusableNodes();
      }
      detailsGroups = NativeHtmlDetailsGroups();
      final sameDocument =
          widget.scriptDocument != null &&
          _renderedScriptDocument == widget.scriptDocument;
      controls = NativeHtmlControlState.fromHtml(sanitized);
      if (sameDocument && previousControls != null) {
        controls!.adoptInteractionState(
          previousControls,
          preserveValues: preserveValues,
        );
      }
      previousControls?.dispose();
      textFields = NativeHtmlTextFieldState.fromHtml(
        controls!.annotateHtml(sanitized),
      );
      if (previousTextFields != null && sameDocument) {
        textFields!.adoptEditingState(
          previousTextFields,
          preserveValues: preserveValues,
        );
      }
      previousTextFields?.dispose();
      _renderedScriptDocument = widget.scriptDocument;
      final textSource = textFields!.annotateHtml(
        controls!.annotateHtml(sanitized),
      );
      ranges = NativeHtmlRangeState.fromHtml(textSource);
      if (sameDocument && previousRanges != null) {
        ranges!.adoptInteractionState(
          previousRanges,
          preserveValues: preserveValues,
        );
      }
      previousRanges?.dispose();
      final rangeSource = ranges!.annotateHtml(textSource);
      selects = NativeHtmlSelectState.fromHtml(rangeSource);
      if (sameDocument && previousSelects != null) {
        selects!.adoptInteractionState(
          previousSelects,
          preserveValues: preserveValues,
        );
      }
      previousSelects?.dispose();
      final selectSource = selects!.annotateHtml(rangeSource);
      dates = NativeHtmlDateState.fromHtml(selectSource);
      if (sameDocument && previousDates != null) {
        dates!.adoptInteractionState(
          previousDates,
          preserveValues: preserveValues,
        );
      }
      previousDates?.dispose();
      final dateSource = dates!.annotateHtml(selectSource);
      files = NativeHtmlFileInputState.fromHtml(dateSource, picker: _pickFiles);
      if (sameDocument && previousFiles != null) {
        files!.adoptInteractionState(previousFiles);
      }
      previousFiles?.dispose();
      final buttonSource = files!.annotateHtml(dateSource);
      buttons = NativeHtmlButtonState.fromHtml(
        buttonSource,
        onReset: resetFormControls,
        onSubmit: (element) => forms!.submitButton(element),
        onClick: _scriptClickHandler,
        locale: WidgetsBinding.instance.platformDispatcher.locale,
        enhanceMarkdown: widget.markdownStyles,
      );
      if (sameDocument && previousButtons != null) {
        buttons!.adoptInteractionState(previousButtons);
      }
      previousButtons?.dispose();
      forms = NativeHtmlForms(
        source: buttons!.annotateHtml(buttonSource),
        textFields: textFields!,
        controls: controls!,
        ranges: ranges!,
        selects: selects!,
        buttons: buttons!,
        dates: dates!,
        files: files!,
        onSubmit: widget.onFormSubmit,
        onSubmitEvent: _documentRuntime == null || widget.onScriptEvent == null
            ? null
            : _handleScriptSubmit,
      );
      sanitizedContent = sanitized;
    }
    // A chooser may finish in a renderer that was replaced while awaiting it.
    // File bytes can change without any corresponding serialized HTML change.
    _scriptFileSelections.reconcile(files!);
    content = buttons!.annotateHtml(
      files!.annotateHtml(
        dates!.annotateHtml(
          selects!.annotateHtml(
            ranges!.annotateHtml(
              textFields!.annotateHtml(controls!.annotateHtml(sanitized)),
            ),
          ),
        ),
      ),
    );
    if (widget.viewport != null) {
      final fragments =
          widget.fragmentIndex ?? NativeDocumentFragmentIndex(content, nonce);
      if (widget.fragmentIndex == null) content = fragments.annotatedHtml;
      widget.viewport!._bindFragments(this, fragments);
      widget.viewport!._bindFragmentFocus(
        this,
        _focusFragmentTarget,
        _currentNativeScriptFocusId,
        _focusedFragmentCaret,
      );
    }
    _pruneScriptFocusableNodes(content);
    _bindScriptControls();
    _renderedScriptSnapshot = widget.scriptSnapshot;
  }

  void _captureSubmissionFiles() {
    if (files == null) return;
    for (final element
        in html.parseFragment(content).querySelectorAll('input')) {
      final field = files!.resolveControl(element);
      final id = field?.scriptId;
      if (field == null || id == null) continue;
      _submissionFiles.putIfAbsent((
        id,
        field.fileResetVersion,
      ), () => List.of(files!.filesFor(field.key)));
    }
  }

  void _scheduleScriptFilePickers() {
    final runtime = _documentRuntime;
    if (runtime == null ||
        _scriptFilePickerScheduled ||
        _scriptFilePickerRunning ||
        widget.scriptFilePickerActions.isEmpty ||
        widget.onScriptFilePickerResult == null) {
      return;
    }
    final callbacks = runtime.scriptCallbacks;
    _scriptFilePickerScheduled = true;
    final owner = widget.scriptDocument;
    final sourceGeneration = _scriptSourceGeneration;
    final documentCurrent = widget.scriptFilePickerIsCurrent;
    final selections = _scriptFileSelections;
    bool current() =>
        (mounted || documentCurrent != null) &&
        (documentCurrent?.call() ?? true) &&
        owner == widget.scriptDocument &&
        (owner != null || sourceGeneration == _scriptSourceGeneration);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scriptFilePickerScheduled = false;
      if (!current()) {
        if (mounted) _scheduleScriptFilePickers();
        return;
      }
      final actions =
          widget.takeScriptFilePickerActions?.call([
            for (final action in widget.scriptFilePickerActions)
              action['sequence'] as int,
          ]) ??
          const <Map<String, dynamic>>[];
      if (actions.isEmpty) return;
      _scriptFilePickerRunning = true;
      final complete = widget.onScriptFilePickerResult!;
      try {
        for (final action in actions) {
          if (!current()) break;
          final pick = callbacks.decodeFilePick(action);
          final id = pick.id;
          final controlId = pick.controlId;
          final version = pick.resetVersion;
          try {
            final picked = await _pickFiles(pick.request);
            if (!current()) {
              // Release a retained VM lease after scope retirement without ever
              // publishing selected bytes into a different document/account.
              if (documentCurrent != null) await complete(id, cancelled: true);
              break;
            }
            if (picked == null) {
              await complete(id, cancelled: true);
              continue;
            }
            final limited = pick.request.multiple
                ? picked
                : picked.take(1).toList();
            if (limited.length > 256) {
              throw StateError(tr("一次最多選取 256 個檔案。"));
            }
            final selected = selections.store(controlId, version, limited);
            if (mounted && files != null) selections.reconcile(files!);
            final (wire, _) = callbacks.encodeFiles(
              selected,
              _scriptFileBytesBudget,
            );
            await complete(id, files: wire);
          } catch (error) {
            if (current()) {
              final message = '$error';
              await complete(
                id,
                error: message.length > 2048
                    ? message.substring(0, 2048)
                    : message,
              );
            } else if (documentCurrent != null) {
              await complete(id, cancelled: true);
            }
          }
        }
      } finally {
        _scriptFilePickerRunning = false;
        if (mounted) _scheduleScriptFilePickers();
      }
    });
  }

  void _scheduleScriptFocusActions() {
    final callbacks = _documentRuntime?.scriptCallbacks;
    if (callbacks == null ||
        _scriptFocusActionsScheduled ||
        callbacks
            .pendingActions(
              widget.scriptFocusActions,
              _lastConsumedScriptFocusSequence,
            )
            .isEmpty) {
      return;
    }
    _scriptFocusActionsScheduled = true;
    final owner = widget.scriptDocument;
    final sourceGeneration = _scriptSourceGeneration;
    final scope = _nativeDocumentScope;
    final identity = scope?.accountIdentity;
    final windows = scope?.windows;
    final window = scope?.window;
    final document = window?.currentDocument;
    final selection = windows?.selectionRevision;
    bool current() =>
        mounted &&
        owner == widget.scriptDocument &&
        sourceGeneration == _scriptSourceGeneration &&
        (scope == null ||
            windows != null &&
                !windows.disposed &&
                identity == windows.accountIdentity &&
                selection == windows.selectionRevision &&
                window?.disposed != true &&
                window?.closing != true &&
                (window == null ||
                    identical(window.currentDocument, document) &&
                        identical(document, owner) &&
                        identical(windows.active, window)));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scriptFocusActionsScheduled = false;
      if (!current()) {
        if (mounted &&
            (owner != widget.scriptDocument ||
                sourceGeneration != _scriptSourceGeneration)) {
          _scheduleScriptFocusActions();
        }
        return;
      }
      final paintedActions = callbacks.pendingActions(
        widget.scriptFocusActions,
        _lastConsumedScriptFocusSequence,
      );
      if (paintedActions.isEmpty) return;
      final actions =
          (widget.takeScriptFocusActions?.call([
                    for (final action in paintedActions)
                      action['sequence'] as int,
                  ]) ??
                  paintedActions)
              .toList();
      if (actions.isEmpty || !current()) return;
      callbacks.sortFocusActions(actions);
      for (final action in actions) {
        if (action['sequence'] is int) {
          _lastConsumedScriptFocusSequence = max(
            _lastConsumedScriptFocusSequence,
            action['sequence'] as int,
          );
        }
      }
      final previousApplying = _applyingScriptFocus;
      final previousEchoIds = _scriptFocusEchoControlIds;
      _applyingScriptFocus = true;
      _scriptFocusEchoControlIds = _scriptFocusEchoIds(actions);
      try {
        _applyScriptFocusActions(actions, isCurrent: current);
        // FocusNode listeners run synchronously when the manager flushes. Keep
        // the echo guard up through the flush, including text blur change.
        FocusManager.instance.applyFocusChangesIfNeeded();
      } finally {
        _applyingScriptFocus = previousApplying;
        _scriptFocusEchoControlIds = previousEchoIds;
      }
    });
  }

  Set<String> _scriptFocusEchoIds(List<Map<String, dynamic>> actions) {
    final ids = <String>{};
    final fragment = html.parseFragment(content);
    for (final element in fragment.querySelectorAll('[data-pirc-script-id]')) {
      final id = element.attributes['data-pirc-script-id'];
      if (id != null &&
          _scriptFocusNodesForElement(element).any((node) => node.hasFocus)) {
        ids.add(id);
      }
    }
    for (final action in actions) {
      final id = action['controlId'];
      if (id is String && id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  void _applyScriptFocusActions(
    List<Map<String, dynamic>> actions, {
    required bool Function() isCurrent,
  }) {
    final fragment = html.parseFragment(content);
    final focusNodes = [
      for (final element
          in fragment
              .querySelectorAll('[data-pirc-script-id]')
              .toList()
              .reversed)
        ..._scriptFocusNodesForElement(element),
    ];
    FocusNode? desired =
        focusNodes.where((node) => node.hasPrimaryFocus).firstOrNull ??
        focusNodes.where((node) => node.hasFocus).firstOrNull ??
        FocusManager.instance.primaryFocus;
    var desiredIsScriptControl =
        focusNodes.any((node) => identical(node, desired)) ||
        _currentNativeScriptFocusId() != null;
    var changedDesired = false;
    var shouldUnfocusDocument = false;
    var preventScroll = true;

    for (final action in actions) {
      final sequence = action['sequence'];
      final actionOrder = action['actionOrder'];
      final id = action['controlId'];
      final kind = action['kind'];
      if (sequence is! int ||
          sequence <= 0 ||
          actionOrder is! int ||
          actionOrder <= 0 ||
          id is! String ||
          (kind != 'focus' && kind != 'blur')) {
        continue;
      }
      final element = _scriptElement(id, fragment);
      if (kind == 'focus') {
        if (element == null) continue;
        final nodes = _scriptFocusNodesForElement(element);
        final target = nodes
            .where((node) => node.canRequestFocus && node.context != null)
            .firstOrNull;
        if (target == null) continue;
        desired = target;
        desiredIsScriptControl = true;
        changedDesired = true;
        preventScroll = action['preventScroll'] == true;
      } else if (desiredIsScriptControl ||
          element != null &&
              _scriptFocusNodesForElement(
                element,
              ).any((node) => identical(node, desired))) {
        desired = null;
        desiredIsScriptControl = false;
        changedDesired = true;
        shouldUnfocusDocument = true;
      }
    }

    if (!changedDesired) return;
    if (desired == null) {
      _cancelFocusRevealSuppression();
      if (!shouldUnfocusDocument || _currentNativeScriptFocusId() == null) {
        return;
      }
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null) {
        primary.unfocus(disposition: UnfocusDisposition.scope);
      }
      return;
    }
    _beginFocusRevealSuppression(desired, preventScroll, isCurrent: isCurrent);
    desired.requestFocus();
    if (!preventScroll) {
      // Closing a dialog can dispose the old focused control during this same
      // frame. Ancestor lookup on its deactivated Element is unsafe. Resolve
      // the live focus context after the tree has finalized instead.
      final target = desired;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !isCurrent() || !target.hasFocus) return;
        final liveContext = target.context;
        if (liveContext == null || !liveContext.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            liveContext,
            duration: Duration.zero,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
      });
      // Script focus actions may run in a post-frame callback. Request another
      // frame so the deferred reveal executes even when nothing else repaints.
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  NativeDocumentFocusCaret? _focusedFragmentCaret() {
    final id = _currentNativeScriptFocusId();
    if (id == null) return null;
    final element = _scriptElement(id, html.parseFragment(content));
    if (element?.localName != 'textarea') return null;
    final field = textFields?.resolveControl(element!);
    if (field == null) return null;
    final object = textFields!
        .editorKeyFor(field.key)
        .currentContext
        ?.findRenderObject();
    if (object == null) return null;
    RenderEditable? editable;
    var visited = 0;
    void find(RenderObject node) {
      if (editable != null || visited++ > 128) return;
      if (node is RenderEditable) {
        editable = node;
        return;
      }
      node.visitChildren(find);
    }

    find(object);
    final surface = editable;
    if (surface == null || !surface.attached || !surface.hasSize) return null;
    final selection = textFields!.controllerFor(field.key).selection;
    return (
      id: id,
      surface: surface,
      rect: surface.getLocalRectForCaret(
        selection.isValid ? selection.extent : const TextPosition(offset: 0),
      ),
    );
  }

  NativeFragmentFocusResult _focusFragmentTarget(
    String? id,
    bool Function() isCurrent,
  ) {
    if (!mounted || !isCurrent() || !_isScriptFocusDocumentCurrent()) {
      return NativeFragmentFocusResult.unavailable;
    }
    final fragment = html.parseFragment(content);
    final element = id == null ? null : _scriptElement(id, fragment);
    final css = widget.layoutComputedStyles[id]?.values;
    final hidden =
        css?['display'] == 'none' ||
        const {'hidden', 'collapse'}.contains(css?['visibility']);
    var inert = false;
    for (var parent = element; parent != null; parent = parent.parent) {
      if (parent.attributes.containsKey('inert')) {
        inert = true;
        break;
      }
    }
    final nodes = element == null || hidden || inert
        ? const <FocusNode>[]
        : _scriptFocusNodesForElement(element);
    final desired = nodes
        .where((node) => node.canRequestFocus && node.context != null)
        .firstOrNull;
    final previous = _currentNativeScriptFocusId();
    if (desired == null) {
      if (previous != null) {
        _cancelFocusRevealSuppression();
        FocusManager.instance.primaryFocus?.unfocus(
          disposition: UnfocusDisposition.scope,
        );
        FocusManager.instance.applyFocusChangesIfNeeded();
      }
      return NativeFragmentFocusResult.unchanged;
    }
    if (previous == id) return NativeFragmentFocusResult.unchanged;
    _beginFocusRevealSuppression(desired, true, isCurrent: isCurrent);
    desired.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    return _currentNativeScriptFocusId() == id
        ? NativeFragmentFocusResult.changed
        : NativeFragmentFocusResult.unchanged;
  }

  List<FocusNode> _scriptFocusNodesForElement(dom.Element element) {
    final textField = textFields?.resolveControl(element);
    if (textField != null) return [textFields!.focusNodeFor(textField.key)];
    final control = controls?.resolveControl(element);
    if (control != null) {
      final focusNode = controls!.focusNodeFor(control.key);
      return focusNode == null ? const [] : [focusNode];
    }
    final select = selects?.resolveControl(element);
    if (select != null) return [selects!.focusNodeFor(select.key)];
    final range = ranges?.resolveControl(element);
    if (range != null) return [ranges!.focusNodeFor(range.key)];
    final date = dates?.resolveControl(element);
    if (date != null) {
      return [
        for (final segment in NativeHtmlDateSegment.values)
          dates!.segmentFocusNodeFor(date.key, segment),
      ];
    }
    final file = files?.resolveControl(element);
    if (file != null) return [files!.focusNodeFor(file.key)];
    final button = buttons?.resolveControl(element);
    if (button != null) return [buttons!.focusNodeFor(button.key)];
    final id = element.attributes['data-pirc-script-id'];
    final anchor =
        element.localName == 'a' && element.attributes.containsKey('href');
    final tabIndex = int.tryParse(element.attributes['tabindex'] ?? '');
    final summary = nativeHtmlDetailsSummaryFor(element) == element;
    final dialog = element.localName == 'dialog';
    if (id == null || (!anchor && !summary && !dialog && tabIndex == null)) {
      return const [];
    }
    final node = _scriptFocusableNodes[id];
    return node == null ? const [] : [node];
  }

  FocusNode _scriptFocusableNode(dom.Element element) {
    final id = element.attributes['data-pirc-script-id'];
    if (id == null || id.isEmpty) {
      throw StateError(tr("Script focus target has no control id."));
    }
    final tabIndex = int.tryParse(element.attributes['tabindex'] ?? '');
    return _scriptFocusableNodes.putIfAbsent(
        id,
        () => FocusNode(debugLabel: 'HTML script focus $id'),
      )
      ..skipTraversal = tabIndex != null
          ? tabIndex < 0
          : element.localName == 'dialog';
  }

  void _cancelFocusRevealSuppression() {
    _focusRevealEpoch++;
    _suppressFocusReveal = false;
    _focusRevealNode = null;
    _focusRevealIsCurrent = null;
  }

  void _beginFocusRevealSuppression(
    FocusNode node,
    bool preventScroll, {
    required bool Function() isCurrent,
  }) {
    _cancelFocusRevealSuppression();
    if (!preventScroll) return;
    _suppressFocusReveal = true;
    _focusRevealNode = node;
    _focusRevealIsCurrent = isCurrent;
    final epoch = _focusRevealEpoch;
    // EditableText schedules caret reveal after focus notifications. Keep the
    // render gate across those layout callbacks, instead of undoing an animated
    // viewport jump after it has already begun. Real input cancels this guard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _focusRevealEpoch) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && epoch == _focusRevealEpoch) {
          _cancelFocusRevealSuppression();
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool _shouldSuppressFocusReveal() =>
      mounted &&
      _suppressFocusReveal &&
      _focusRevealNode?.hasFocus == true &&
      _isScriptFocusDocumentCurrent() &&
      _focusRevealIsCurrent?.call() == true;

  void _retireAllScriptFocusableNodes() {
    if (_scriptFocusableNodes.isEmpty) return;
    _retiredScriptFocusableNodes.addAll(_scriptFocusableNodes.values);
    _scriptFocusableNodes.clear();
    _scheduleRetiredScriptFocusableNodeDisposal();
  }

  void _pruneScriptFocusableNodes(String source) {
    if (_scriptFocusableNodes.isEmpty) return;
    final liveIds = html
        .parseFragment(source)
        .querySelectorAll('[data-pirc-script-id]')
        .map((element) => element.attributes['data-pirc-script-id'])
        .whereType<String>()
        .toSet();
    final retiredIds = _scriptFocusableNodes.keys
        .where((id) => !liveIds.contains(id))
        .toList();
    for (final id in retiredIds) {
      _retiredScriptFocusableNodes.add(_scriptFocusableNodes.remove(id)!);
    }
    _scheduleRetiredScriptFocusableNodeDisposal();
  }

  void _scheduleRetiredScriptFocusableNodeDisposal() {
    if (_retiredScriptFocusNodeDisposalScheduled ||
        _retiredScriptFocusableNodes.isEmpty) {
      return;
    }
    _retiredScriptFocusNodeDisposalScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retiredScriptFocusNodeDisposalScheduled = false;
      if (!mounted) return;
      final detached = _retiredScriptFocusableNodes
          .where((node) => node.context == null)
          .toList();
      for (final node in detached) {
        _retiredScriptFocusableNodes.remove(node);
        node.dispose();
      }
    });
  }

  void _handleNativeFocusChange() {
    final focusedId = _currentNativeScriptFocusId();
    if (_applyingScriptFocus) {
      _lastNativeScriptFocusId = focusedId;
      return;
    }
    final previousId = _lastNativeScriptFocusId;
    if (previousId == focusedId) return;
    _lastNativeScriptFocusId = focusedId;
    if (!_isScriptFocusDocumentCurrent()) return;
    if (previousId != null) {
      _dispatchNativeScriptFocusEvent(
        previousId,
        'blur',
        relatedTarget: focusedId,
      );
      _dispatchNativeScriptFocusEvent(
        previousId,
        'focusout',
        relatedTarget: focusedId,
      );
    }
    if (focusedId != null) {
      _dispatchNativeScriptFocusEvent(
        focusedId,
        'focus',
        relatedTarget: previousId,
      );
      _dispatchNativeScriptFocusEvent(
        focusedId,
        'focusin',
        relatedTarget: previousId,
      );
    }
  }

  bool _isScriptFocusDocumentCurrent() {
    if (!mounted) return false;
    final scope = _nativeDocumentScope;
    if (scope == null) return true;
    final windows = scope.windows;
    final window = scope.window;
    return !windows.disposed &&
        scope.accountIdentity == windows.accountIdentity &&
        window?.disposed != true &&
        window?.closing != true &&
        (window == null ||
            identical(window.currentDocument, widget.scriptDocument) &&
                identical(windows.active, window));
  }

  String? _currentNativeScriptFocusId() {
    final fragment = html.parseFragment(content);
    final elements = fragment
        .querySelectorAll('[data-pirc-script-id]')
        .toList()
        .reversed;
    for (final element in elements) {
      // A native select keeps DOM focus while Flutter focuses its popup route.
      // Use that logical ownership rather than emitting a spurious blur.
      final select = selects?.resolveControl(element);
      if (select != null && selects!.hasLogicalFocus(select.key)) {
        return element.attributes['data-pirc-script-id'];
      }
      if (_scriptFocusNodesForElement(element).any((node) => node.hasFocus)) {
        return element.attributes['data-pirc-script-id'];
      }
    }
    return null;
  }

  void _dispatchNativeScriptFocusEvent(
    String id,
    String type, {
    required String? relatedTarget,
  }) {
    final callback = widget.onScriptDetailedEvent;
    if (callback == null || !_isScriptFocusDocumentCurrent()) return;
    unawaited(
      callback(id, type, _scriptControlValues(), {
        'relatedTarget': relatedTarget,
      }).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void _scheduleScriptFormActions() {
    final callbacks = _documentRuntime?.scriptCallbacks;
    if (callbacks == null ||
        _scriptFormActionsScheduled ||
        callbacks
            .pendingActions(widget.scriptFormActions, _lastConsumedFormAction)
            .isEmpty) {
      return;
    }
    _scriptFormActionsScheduled = true;
    final owner = widget.scriptDocument;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scriptFormActionsScheduled = false;
      if (!mounted) return;
      if (owner != widget.scriptDocument) {
        _scheduleScriptFilePickers();
        _scheduleScriptFormActions();
        return;
      }
      final paintedActions = callbacks.pendingActions(
        widget.scriptFormActions,
        _lastConsumedFormAction,
      );
      final actions =
          widget.takeScriptFormActions?.call([
            for (final action in paintedActions) action['sequence'] as int,
          ]) ??
          paintedActions;
      for (final action in actions) {
        _lastConsumedFormAction = max(
          _lastConsumedFormAction,
          action['sequence'] as int,
        );
      }
      widget.onScriptFormActionsConsumed?.call([
        for (final action in actions)
          if (action['sequence'] is int) action['sequence'] as int,
      ]);
      _captureSubmissionFiles();
      try {
        for (final action in actions) {
          if (!mounted || owner != widget.scriptDocument) break;
          if (action['kind'] == 'invalid') {
            forms?.showScriptInvalid(
              '${action['controlId']}',
              '${action['message'] ?? 'Please check this field.'}',
            );
            continue;
          }
          if (action['kind'] != 'submit') continue;
          try {
            final runtime = _documentRuntime;
            if (runtime == null) {
              throw StateError(
                tr("Form navigation is unavailable in this document."),
              );
            }
            final request = runtime.decodeScriptFormSubmission(
              action,
              resolveFile: (id, version, index) {
                final selection =
                    _submissionFiles[(id, version)] ??
                    _scriptFileSelections.get(id, version);
                return selection != null && index < selection.length
                    ? selection[index]
                    : null;
              },
            );
            final submit = widget.onFormSubmit;
            if (submit == null) {
              throw StateError(
                tr("Form navigation is unavailable in this document."),
              );
            }
            submit(request);
          } catch (error) {
            forms?.showScriptError(tr("Form submission failed: {0}", [error]));
          }
        }
      } finally {
        _submissionFiles.clear();
      }
    });
  }

  void _bindScriptControls() {
    // Without a document runtime (chat content) no script callback is bound.
    final scripted = _documentRuntime != null;
    final onEvent = scripted ? widget.onScriptEvent : null;
    final onDetailedEvent = scripted ? widget.onScriptDetailedEvent : null;
    final onControlClick = scripted ? widget.onScriptControlClick : null;
    final onFilePickerResult = scripted
        ? widget.onScriptFilePickerResult
        : null;
    final onFormActionsConsumed = scripted
        ? widget.onScriptFormActionsConsumed
        : null;
    final callback = onEvent == null ? null : _scriptControlEvent;
    textFields?.onUserEvent = onDetailedEvent == null ? callback : null;
    textFields?.onDetailedUserEvent = onDetailedEvent == null
        ? null
        : (key, type, data) =>
              unawaited(_scriptControlDetailedEvent(key, type, data));
    textFields?.onUserKeyEvent = onDetailedEvent == null
        ? null
        : _scriptControlDetailedEvent;
    controls?.onUserEvent = callback;
    controls?.onActivateControl = onControlClick == null
        ? null
        : _scriptCheckableClick;
    selects?.onUserEvent = onDetailedEvent == null ? callback : null;
    selects?.onDetailedUserEvent = onDetailedEvent == null
        ? null
        : (key, type, data) =>
              unawaited(_scriptControlDetailedEvent(key, type, data));
    selects?.onUserKeyEvent = onDetailedEvent == null
        ? null
        : _scriptControlDetailedEvent;
    ranges?.onUserEvent = callback;
    dates?.onUserEvent = callback;
    files?.onUserEvent = callback;
    files?.onActivateControl = onFilePickerResult != null && onEvent != null
        ? _scriptFileClick
        : null;
    forms?.onSubmitEvent = onEvent == null ? null : _handleScriptSubmit;
    forms?.onRequestSubmit =
        onFormActionsConsumed != null && onControlClick != null
        ? _requestScriptSubmit
        : null;
  }

  Future<void> _scriptFileClick(String key) async {
    final element = html
        .parseFragment(content)
        .querySelectorAll('input')
        .where((e) => files?.resolveControl(e)?.key == key)
        .firstOrNull;
    if (element == null) return;
    final id = element.attributes['data-pirc-script-id'];
    await _handleElementTap(element, () {
      final current = _scriptElement(id, html.parseFragment(content));
      final control = current == null ? null : files?.resolveControl(current);
      if (control != null) {
        unawaited(files!.pick(control.key, skipScript: true));
      }
    });
  }

  void _scriptCheckableClick(String key) {
    final callback = widget.onScriptControlClick;
    if (callback == null || !mounted) return;
    _flushNativeFocusBeforeScriptEvent('click');
    final element = html
        .parseFragment(content)
        .querySelectorAll('[data-pirc-script-id]')
        .where((e) => controls?.resolveControl(e)?.key == key)
        .firstOrNull;
    final id = element?.attributes['data-pirc-script-id'];
    if (id == null) return;
    // Resolve against this document before queuing. The runtime serializes
    // activation, cancellation and input/change, then publishes checked state.
    unawaited(
      callback(
        id,
        _scriptControlValues(),
      ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  Offset _canvasViewportOrigin() {
    final object = context.findRenderObject();
    final viewport = RenderAbstractViewport.maybeOf(object);
    return viewport is RenderBox
        ? (viewport as RenderBox).localToGlobal(Offset.zero)
        : Offset.zero;
  }

  bool _canvasDisablesPanning(dom.Element element, bool specified) {
    if (specified) return true;
    for (
      dom.Element? current = element;
      current != null;
      current = current.parent
    ) {
      final author = widget.authorStylesBuilder?.call(current);
      var value = author?['touch-action'];
      if (value == null) {
        final parsed = css_parser.parse(
          '* { ${current.attributes['style'] ?? ''} }',
        );
        for (final rule in parsed.topLevels.whereType<css.RuleSet>()) {
          for (final declaration
              in rule.declarationGroup.declarations
                  .whereType<css.Declaration>()) {
            if (declaration.property != 'touch-action') continue;
            final printer = css.CssPrinter();
            declaration.expression?.visit(printer);
            value = printer.toString().trim();
          }
        }
      }
      if (value?.trim().toLowerCase() == 'none') return true;
    }
    return false;
  }

  Widget _canvasPointerSurface(
    dom.Element element,
    Widget child,
    bool touchActionNone,
  ) {
    final callback = widget.onScriptDetailedEvent;
    final owner = widget.scriptDocument;
    final id = element.attributes['data-pirc-script-id'];
    final runtime = _documentContextRuntime;
    if (callback == null || owner == null || id == null || runtime == null) {
      return child;
    }
    return runtime.canvasPointerSurface(
      key: _canvasPointerKeys.putIfAbsent(id, () => GlobalKey()),
      documentIdentity: owner,
      elementId: id,
      touchActionNone: _canvasDisablesPanning(element, touchActionNone),
      viewportOrigin: _canvasViewportOrigin,
      onEvent: (type, data) async {
        if (!mounted || owner != widget.scriptDocument) return true;
        final currentCallback = widget.onScriptDetailedEvent;
        if (currentCallback == null) return true;
        return currentCallback(
          id,
          type,
          type == 'click' ? _scriptControlValues() : const [],
          data,
        );
      },
      onTouchClickQueued: (data) {
        if (!mounted || owner != widget.scriptDocument) return null;
        final currentCallback = widget.onScriptTouchClickQueued;
        if (currentCallback == null) return null;
        return currentCallback(id, data);
      },
      child: child,
    );
  }

  Future<bool> _scriptControlDetailedEvent(
    String key,
    String type,
    Map<String, dynamic> eventData,
  ) async {
    if (_isScriptFocusEvent(type)) return false;
    final callback = widget.onScriptDetailedEvent;
    if (callback == null || !mounted) return false;
    final element = html
        .parseFragment(content)
        .querySelectorAll('[data-pirc-script-id]')
        .where(
          (e) =>
              textFields?.resolveControl(e)?.key == key ||
              selects?.resolveControl(e)?.key == key,
        )
        .firstOrNull;
    var id = element?.attributes['data-pirc-script-id'];
    final optionIndex = eventData['optionIndex'];
    if (type == 'click' &&
        element?.localName == 'select' &&
        optionIndex is int) {
      final options = element!.querySelectorAll('option');
      if (optionIndex >= 0 && optionIndex < options.length) {
        id = options[optionIndex].attributes['data-pirc-script-id'] ?? id;
      }
    }
    if (id == null) return false;
    final isTextField = textFields?.resolveControl(element!) != null;
    if (_shouldSuppressScriptFocusEcho(id, type, textField: isTextField)) {
      return false;
    }
    _flushNativeFocusBeforeScriptEvent(type);
    final owner = widget.scriptDocument;
    final generation = _scriptSourceGeneration;
    final textField = isTextField ? textFields!.resolveControl(element!) : null;
    final nativeEventData =
        type == 'change' &&
            textField != null &&
            !textFields!.focusNodeFor(textField.key).hasFocus
        ? <String, dynamic>{...eventData, 'focusLeaving': true}
        : eventData;
    try {
      final prevented = await callback(
        id,
        type,
        _scriptControlValues(),
        nativeEventData,
      );
      // A keydown handler can change form ownership/action. Adopt the script
      // snapshot before the editor continues its implicit submit default.
      if (!prevented && type == 'keydown' && eventData['key'] == 'Enter') {
        await WidgetsBinding.instance.endOfFrame;
      }
      return prevented ||
          !mounted ||
          owner != widget.scriptDocument ||
          (owner == null && generation != _scriptSourceGeneration);
    } catch (_) {
      return !mounted || owner != widget.scriptDocument;
    }
  }

  void _scriptControlEvent(String key, String type) {
    if (_isScriptFocusEvent(type)) return;
    final callback = widget.onScriptEvent;
    if (callback == null || !mounted) return;
    final fragment = html.parseFragment(content);
    final element = fragment
        .querySelectorAll('[data-pirc-script-id]')
        .where(
          (e) =>
              textFields?.resolveControl(e)?.key == key ||
              controls?.resolveControl(e)?.key == key ||
              selects?.resolveControl(e)?.key == key ||
              ranges?.resolveControl(e)?.key == key ||
              dates?.resolveControl(e)?.key == key ||
              files?.resolveControl(e)?.key == key,
        )
        .firstOrNull;
    final id = element?.attributes['data-pirc-script-id'];
    if (id == null) return;
    final isTextField = textFields?.resolveControl(element!) != null;
    if (_shouldSuppressScriptFocusEcho(id, type, textField: isTextField)) {
      return;
    }
    _flushNativeFocusBeforeScriptEvent(type);
    unawaited(
      callback(
        id,
        type,
        _scriptControlValues(),
      ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  bool _isScriptFocusEvent(String type) =>
      const {'focus', 'blur', 'focusin', 'focusout'}.contains(type);

  bool _shouldSuppressScriptFocusEcho(
    String id,
    String type, {
    required bool textField,
  }) =>
      _applyingScriptFocus &&
      _scriptFocusEchoControlIds.contains(id) &&
      (_isScriptFocusEvent(type) || (textField && type == 'change'));

  void _flushNativeFocusBeforeScriptEvent(String type) {
    if (!_applyingScriptFocus &&
        !_isScriptFocusEvent(type) &&
        type != 'change') {
      _cancelFocusRevealSuppression();
    }
    if (_applyingScriptFocus || _isScriptFocusEvent(type) || type == 'change') {
      return;
    }
    FocusManager.instance.applyFocusChangesIfNeeded();
  }

  Future<void> _requestScriptSubmit(
    dom.Element form,
    dom.Element? submitter,
  ) async {
    final id = form.attributes['data-pirc-script-id'];
    final callback = widget.onScriptEvent;
    if (id == null || callback == null) return;
    final owner = widget.scriptDocument;
    try {
      await callback(
        id,
        'requestSubmit',
        _scriptControlValues(),
        submitter: submitter?.attributes['data-pirc-script-id'],
      );
    } catch (error) {
      if (mounted && owner == widget.scriptDocument) {
        forms?.showScriptError(tr("Form submission failed: {0}", [error]));
      }
    }
  }

  Future<bool> _handleScriptSubmit(
    dom.Element form,
    dom.Element? submitter,
  ) async {
    final callback = widget.onScriptEvent;
    final id = form.attributes['data-pirc-script-id'];
    if (callback == null || id == null) return false;
    final owner = widget.scriptDocument;
    final submitterId = submitter?.attributes['data-pirc-script-id'];
    bool prevented;
    try {
      prevented = await callback(
        id,
        'submit',
        _scriptControlValues(),
        submitter: submitterId,
      );
    } catch (_) {
      return !mounted || owner != widget.scriptDocument;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || owner != widget.scriptDocument || prevented) return true;
    // The handler may have changed values, action or method. Build the native
    // request from the current DOM, after validation and the submit event.
    forms?.submitScriptForm(id, submitterId);
    return true;
  }

  Future<List<NativeHtmlFile>?> _pickFiles(
    NativeHtmlFilePickerRequest request,
  ) async {
    final injected = widget.filePicker;
    if (injected != null) return injected(request);
    final host = RenderHost.of(context);
    final scope = host.documentScope(context);
    final pickerFor = host.filePickerFor;
    if (scope == null || pickerFor == null) {
      throw UnsupportedError(
        tr("File selection is unavailable in this document."),
      );
    }
    final identity = scope.accountIdentity;
    final windows = scope.windows;
    final window = scope.window;
    final document = window?.currentDocument;
    final selection = windows.selectionRevision;
    final retained = widget.retainedControls;
    final scriptCurrent = widget.scriptFilePickerIsCurrent;
    return pickerFor(
      scope,
      isCurrent: () =>
          (retained == null
              ? (scriptCurrent?.call() ?? mounted)
              : !retained.isDisposed) &&
          !windows.disposed &&
          identity == windows.accountIdentity &&
          selection == windows.selectionRevision &&
          window?.disposed != true &&
          window?.closing != true &&
          (window == null || identical(window.currentDocument, document)),
    )(request);
  }

  dom.Element? _scriptElement(String? id, dom.DocumentFragment fragment) =>
      id == null
      ? null
      : fragment
            .querySelectorAll('[data-pirc-script-id]')
            .where((element) => element.attributes['data-pirc-script-id'] == id)
            .firstOrNull;

  Future<void> _handleElementTap(
    dom.Element element,
    VoidCallback? defaultAction,
  ) async {
    final event = widget.onScriptEvent;
    final click = widget.onScriptClick;
    final id = element.attributes['data-pirc-script-id'];
    if (id == null || (event == null && click == null)) {
      defaultAction?.call();
      return;
    }
    _flushNativeFocusBeforeScriptEvent('click');
    final owner = widget.scriptDocument;
    final generation = _scriptSourceGeneration;
    bool isCurrent() =>
        mounted &&
        owner == widget.scriptDocument &&
        (owner != null || generation == _scriptSourceGeneration);
    dom.Element? anchor = element;
    while (anchor != null && anchor.localName != 'a') {
      anchor = anchor.parent;
    }
    final anchorId = anchor?.attributes['data-pirc-script-id'];
    dom.Element? label = element;
    while (label != null && label.localName != 'label') {
      label = label.parent;
    }
    final labelId = label?.attributes['data-pirc-script-id'];
    bool prevented;
    try {
      prevented = event != null
          ? await event(id, 'click', _scriptControlValues())
          : await click!(id, _scriptControlValues());
    } catch (_) {
      // Retain the same failure fallback as native buttons, only in this document.
      if (isCurrent()) defaultAction?.call();
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!isCurrent() || prevented) return;
    final fragment = html.parseFragment(content);
    final current = _scriptElement(id, fragment);
    if (anchor != null) {
      final updatedAnchor = _scriptElement(anchorId, fragment);
      final href = updatedAnchor?.attributes['href'];
      if (href == null) return;
      final link = NativeHtmlLink(
        href,
        target: updatedAnchor!.attributes['target'] ?? '',
        download: updatedAnchor.attributes['download'],
        referrerPolicy: updatedAnchor.attributes['referrerpolicy'],
        noopener: nativeHtmlNoopener(updatedAnchor.attributes['rel']),
        noreferrer: (updatedAnchor.attributes['rel'] ?? '')
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .contains('noreferrer'),
        targetSpecified: updatedAnchor.attributes.containsKey('target'),
      );
      if (widget.onNavigate != null) {
        widget.onNavigate!(link);
      } else {
        widget.onLink?.call(href);
      }
      return;
    }
    // A snapshot replaces the control-state objects. Resolve label defaults
    // against the current document instead of activating a disposed factory.
    final currentLabel = _scriptElement(labelId, fragment);
    if (currentLabel != null) {
      if (controls?.resolveLabel(currentLabel) != null) {
        controls!.activateLabel(currentLabel);
      } else if (textFields?.resolveLabel(currentLabel) != null) {
        textFields!.activateLabel(currentLabel);
      } else if (selects?.resolveLabel(currentLabel) != null) {
        selects!.activateLabel(currentLabel);
      } else if (ranges?.resolveLabel(currentLabel) != null) {
        ranges!.activateLabel(currentLabel);
      } else if (dates?.resolveLabel(currentLabel) != null) {
        dates!.activateLabel(currentLabel);
      } else if (files?.resolveLabel(currentLabel) != null) {
        files!.activateLabel(currentLabel);
      } else {
        buttons?.activateLabel(currentLabel);
      }
      return;
    }
    if (current != null) defaultAction?.call();
  }

  Future<bool> Function(dom.Element)? get _scriptClickHandler =>
      _documentRuntime == null ||
          (widget.onScriptClick == null && widget.onScriptEvent == null)
      ? null
      : _handleScriptClick;

  Future<bool> _handleScriptClick(dom.Element button) async {
    _flushNativeFocusBeforeScriptEvent('click');
    final callback = widget.onScriptClick;
    final id = button.attributes['data-pirc-script-id'];
    final event = widget.onScriptEvent;
    if (event != null && id != null) {
      final owner = widget.scriptDocument;
      bool prevented;
      try {
        prevented = await event(id, 'click', _scriptControlValues());
      } catch (_) {
        return !mounted || owner != widget.scriptDocument;
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || owner != widget.scriptDocument || prevented) return true;
      final current = html
          .parseFragment(content)
          .querySelectorAll('[data-pirc-script-id]')
          .where((e) => e.attributes['data-pirc-script-id'] == id)
          .firstOrNull;
      final descriptor = current == null
          ? null
          : buttons?.resolveControl(current);
      if (descriptor?.type == NativeHtmlButtonType.reset && current != null) {
        final formId = forms
            ?.formForButton(current)
            ?.attributes['data-pirc-script-id'];
        if (formId != null) {
          await event(formId, 'reset', _scriptControlValues());
          return true;
        }
      }
      if (descriptor != null) {
        await buttons!.activate(descriptor.key, skipScript: true);
      }
      return true;
    }
    if (callback == null || id == null) return false;
    final sourceGeneration = _scriptSourceGeneration;
    try {
      final prevented = await callback(id, _scriptControlValues());
      if (!mounted || sourceGeneration != _scriptSourceGeneration) return true;
      return prevented;
    } catch (_) {
      // A failed script handler leaves the native default action available,
      // unless its source document has already been replaced.
      return !mounted || sourceGeneration != _scriptSourceGeneration;
    }
  }

  List<Map<String, dynamic>> _scriptControlValues() {
    final values = <Map<String, dynamic>>[];
    final callbacks = _documentRuntime?.scriptCallbacks;
    if (callbacks == null) return values;
    final fragment = html.parseFragment(content);
    // Keep selected content inside the 4 MiB isolate message limit after base64.
    // Native form submissions retain their independent, larger upload limit.
    var fileBytesRemaining = _scriptFileBytesBudget;
    for (final element in fragment.querySelectorAll('[data-pirc-script-id]')) {
      if (!const {'input', 'textarea', 'select'}.contains(element.localName)) {
        continue;
      }
      final id = element.attributes['data-pirc-script-id'];
      if (id == null) continue;
      final value = <String, dynamic>{'id': id};
      final check = controls?.resolveControl(element);
      if (check != null) {
        // A queued event may carry an older native snapshot. Never overwrite
        // script-owned checked state, even from another control's event.
        if (widget.onScriptControlClick != null) continue;
        value['checked'] = controls!.isChecked(check.key);
        values.add(value);
        continue;
      }
      final select = selects?.resolveControl(element);
      if (select != null) {
        if (widget.onScriptEvent != null) {
          value['selectedIndices'] = selects!.selectedIndices(select.key);
        }
        value['selectedValues'] = selects!
            .selectedIndices(select.key)
            .where((index) => index >= 0 && index < select.options.length)
            .map((index) => select.options[index].value)
            .toList(growable: false);
        values.add(value);
        continue;
      }
      final range = ranges?.resolveControl(element);
      if (range != null) {
        value['value'] = ranges!.valueFor(range.key);
        values.add(value);
        continue;
      }
      final date = dates?.resolveControl(element);
      if (date != null) {
        value['value'] = dates!.valueFor(date.key);
        if (widget.onScriptFormActionsConsumed != null) {
          value.addAll(forms!.scriptControlState(element));
        }
        values.add(value);
        continue;
      }
      final text = textFields?.resolveControl(element);
      if (text != null) {
        value['value'] = textFields!.valueFor(text.key);
        if (widget.onScriptFormActionsConsumed != null) {
          value.addAll(forms!.scriptControlState(element));
        }
        values.add(value);
        continue;
      }
      final file = files?.resolveControl(element);
      if (file != null) {
        value['fileResetVersion'] = file.fileResetVersion;
        final (encoded, remaining) = callbacks.encodeFiles(
          files!.filesFor(file.key),
          fileBytesRemaining,
        );
        fileBytesRemaining = remaining;
        value['files'] = encoded;
        values.add(value);
      }
    }
    return values;
  }

  void resetFormControls(List<dom.Element> elements) {
    files!.resetElements(elements);
    dates!.resetDefaults(
      elements
          .map(dates!.resolveControl)
          .whereType<NativeHtmlDateDescriptor>()
          .map((e) => e.key),
    );
    controls!.resetDefaults(
      elements
          .map(controls!.resolveControl)
          .whereType<NativeHtmlControlDescriptor>()
          .map((e) => e.key),
    );
    textFields!.resetDefaults(
      elements
          .map(textFields!.resolveControl)
          .whereType<NativeHtmlTextFieldDescriptor>()
          .map((e) => e.key),
    );
    ranges!.resetDefaults(
      elements
          .map(ranges!.resolveControl)
          .whereType<NativeHtmlRangeDescriptor>()
          .map((e) => e.key),
    );
    selects!.resetDefaults(
      elements
          .map(selects!.resolveControl)
          .whereType<NativeHtmlSelectDescriptor>()
          .map((e) => e.key),
    );
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    _elementScroll.retainIds(widget.layoutKnownIds);
    final colors = Theme.of(context).extension<RenderColors>()!;
    final imageViewport = widget.imageViewport ?? MediaQuery.sizeOf(context);
    final imageDpr = MediaQuery.devicePixelRatioOf(context);
    final imageDark =
        widget.imageDark ?? Theme.of(context).brightness == Brightness.dark;
    final scope = RenderHost.of(context).documentScope(context);
    final objectUrls = NativeDocumentObjectUrlScope.maybeOf(context)?.binding;
    final account = scope?.accountIdentity;
    // CSS background images have no tap target to hold them behind, so held
    // content never loads a remote one (inline data: and local blob: do).
    final holdRemote = NativeRemoteContentPolicy.holdsRemoteContent(context);
    final backgroundOwner = scope?.window ?? scope?.windows ?? this;
    final currentDocument = scope?.window?.currentDocument;
    final backgroundBase = currentDocument?.url == scope?.documentUrl
        ? currentDocument?.effectiveBase ?? scope?.documentUrl
        : scope?.documentUrl;
    ImageProvider? backgroundImage(String url) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !['', 'http', 'https', 'data', 'blob'].contains(uri.scheme)) {
        return null;
      }
      if (uri.scheme == 'blob' && objectUrls == null) return null;
      if (uri.scheme != 'data' && uri.scheme != 'blob' && scope == null) {
        return null;
      }
      if (holdRemote && nativeRemoteContentSource(uri)) return null;
      return NativeDocumentBackgroundImage(
        source: uri,
        objectUrls: objectUrls,
        fetcher: scope?.windows.imageFetcher,
        baseUrl: backgroundBase,
        documentUrl: scope?.documentUrl,
        svgCache: _backgroundSvgCache,
        accountIdentity: account ?? this,
        owner: backgroundOwner,
        isCurrent: () =>
            mounted &&
            (uri.scheme != 'blob' || objectUrls?.current == true) &&
            (scope == null ||
                !scope.windows.disposed &&
                    account == scope.windows.accountIdentity &&
                    scope.window?.disposed != true),
      );
    }

    Widget? mediaWidget(dom.Element element) {
      final NativeHtmlMediaSpec spec;
      try {
        spec = NativeHtmlMediaSpec.fromElement(element);
      } on FormatException {
        return Text(tr("Unable to play media."));
      }
      final styles =
          widget.authorStylesBuilder?.call(element) ?? <String, String>{};
      if (widget.authorStylesBuilder == null) {
        final parsed = css_parser.parse(
          '* { ${element.attributes['style'] ?? ''} }',
        );
        for (final rule in parsed.topLevels.whereType<css.RuleSet>()) {
          for (final declaration
              in rule.declarationGroup.declarations
                  .whereType<css.Declaration>()) {
            final printer = css.CssPrinter();
            declaration.expression?.visit(printer);
            styles[declaration.property] = printer.toString().trim();
          }
        }
      }
      if (widget.mediaBuilder != null) {
        return widget.mediaBuilder!(spec, styles);
      }
      final media = RenderHost.of(context).mediaBuilder;
      if (media == null) return null;
      return media(
        scope,
        spec,
        styles,
        baseUrl: backgroundBase,
        accountIdentity: account,
      );
    }

    String cssColor(Color c) =>
        'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a})';
    final document = NativeSelectionGroup(
      blockSeparation: true,
      child: NativeHtmlVisibleInlineOverflowRoot(
        child: HtmlWidget(
          content,
          key: widget.viewport?.key ?? ValueKey(sanitizedContent),
          buildAsync: false,
          enableCaching: true,
          rebuildTriggers: [
            widget.markdownStyles,
            widget.imageViewport,
            widget.authorStylesBuilder,
            widget.canvases,
            widget.canvasImages,
            widget.vectorImageSources,
            widget.htmlImages,
            widget.deferImageLoading,
            widget.layoutController,
            widget.layoutOffsetSpecs,
            widget.documentTopMargins,
            widget.documentPercentTopMargins,
            widget.elementScrollController,
            widget.layoutRevision,
            account,
            backgroundOwner,
            holdRemote,
            imageViewport,
            imageDpr,
            imageDark,
          ],
          textStyle: widget.style.copyWith(
            letterSpacing: widget.style.letterSpacing ?? 0,
          ),
          factoryBuilder: () => _NativeHtmlFactory(
            widget.imageBuilder,
            controls!,
            textFields!,
            selects!,
            ranges!,
            dates!,
            files!,
            _scriptFocusableNode,
            detailsGroups!,
            widget.onDetailsActivate,
            buttons!,
            forms!,
            widget.markdownStyles,
            () => _documentViewport != null,
            () =>
                context
                    .findAncestorWidgetOfExactType<
                      NativeDocumentPositioningViewport
                    >() !=
                null,
            widget.onNavigate,
            _documentRuntime == null ||
                    (widget.onScriptEvent == null &&
                        widget.onScriptClick == null)
                ? null
                : (element, action) =>
                      unawaited(_handleElementTap(element, action)),
            Theme.of(context).brightness == Brightness.dark,
            widget.style.fontFamilyFallback,
            slots,
            widget.builders,
            backgroundImage,
            mediaWidget,
            () => widget.canvases,
            () => widget.canvasImages,
            _canvasPointerSurface,
            () =>
                widget.onScriptDetailedEvent != null &&
                widget.scriptDocument != null,
            () => widget.imageViewport ?? MediaQuery.sizeOf(context),
            () => MediaQuery.devicePixelRatioOf(context),
            () =>
                widget.imageDark ??
                Theme.of(context).brightness == Brightness.dark,
            () => widget.layoutController,
            () => widget.layoutOffsetSpecs,
            () => widget.layoutComputedStyles,
            () => widget.documentPercentTopMargins,
            () => widget.layoutRevision,
            () => _elementScroll,
            () => widget.htmlImages,
            () => widget.vectorImageSources,
            () => widget.deferImageLoading,
            () => _documentContextRuntime,
          ),
          onTapUrl: (url) {
            if (widget.viewport?.resolvingAnchorUrl(url) == true) return false;
            widget.onLink?.call(url);
            return true;
          },
          customStylesBuilder: (element) {
            final tag = element.localName;
            final styles = <String, String>{};
            if (tag == 'dialog') {
              styles['display'] = element.attributes.containsKey('open')
                  ? 'block'
                  : 'none';
            }
            if (!widget.markdownStyles) {
              if (tag == 'form') styles['display'] = 'block';
              if (const {
                'head',
                'title',
                'meta',
                'base',
                'link',
                'style',
                'script',
              }.contains(tag)) {
                styles['display'] = 'none';
              }
              if (tag == 'a' && element.attributes.containsKey('href')) {
                styles.addAll({
                  'color': '#0000ee',
                  'text-decoration': 'underline',
                });
              }
              final author = widget.authorStylesBuilder?.call(element) ?? {};
              styles.addAll(author);
              final topMargin =
                  widget.documentTopMargins[element
                      .attributes['data-pirc-document-style']];
              final percentGroup =
                  widget.documentPercentTopMargins[element
                      .attributes['data-pirc-document-style']];
              if (widget.imageViewport != null && percentGroup != null) {
                styles['margin-top'] = '0px';
              } else if (widget.imageViewport != null && topMargin != null) {
                styles['margin-top'] = '${topMargin}px';
              }
              // The document cascade emits physical border longhands. The HTML
              // core reads border-left/right/top/bottom but ignores their
              // width/style/color longhands, so bridge the resolved winners
              // without re-running or changing the author cascade.
              for (final side in const ['top', 'right', 'bottom', 'left']) {
                final prefix = 'border-$side';
                if (!author.keys.any(
                  (key) =>
                      key.startsWith('$prefix-') && !key.endsWith('radius'),
                )) {
                  continue;
                }
                final rawWidth = author['$prefix-width'] ?? '3px';
                final width = switch (rawWidth) {
                  'thin' => '1px',
                  'medium' => '3px',
                  'thick' => '5px',
                  _ => rawWidth,
                };
                styles[prefix] =
                    '$width ${author['$prefix-style'] ?? 'none'} ${author['$prefix-color'] ?? 'currentColor'}';
              }
              return styles.isEmpty ? null : styles;
            }
            if (tag == 'form') styles['display'] = 'block';
            if (['p', 'ul', 'ol', 'blockquote', 'hr'].contains(tag) ||
                element.classes.contains('code-block')) {
              styles['margin'] = '0 0 0.85em';
            }
            if (RegExp(r'^h[1-6]$').hasMatch(tag ?? '')) {
              styles.addAll({
                'margin': '1.3em 0 0.5em',
                'line-height': '1.35',
                'font-weight': '700',
                'color': cssColor(colors['text.primary']),
                'font-size': switch (tag) {
                  'h1' => '1.35em',
                  'h2' => '1.2em',
                  'h3' => '1.08em',
                  _ => '1em',
                },
              });
            }
            if (tag == 'a') {
              styles.addAll({
                'color': cssColor(colors['accent.default']),
                'text-decoration': 'underline',
                'text-decoration-color': cssColor(
                  colors['accent.default'].withValues(alpha: .35),
                ),
              });
            }
            if (tag == 'strong') {
              styles.addAll({
                'font-weight': '700',
                'color': cssColor(colors['text.primary']),
              });
            }
            if (tag == 'blockquote') {
              styles.addAll({
                'padding': '0.1em 0 0.1em 0.95em',
                'border-left': '3px solid ${cssColor(colors['line.strong'])}',
                'color': cssColor(colors['text.muted']),
              });
            }
            if (tag == 'ul' || tag == 'ol') styles['padding-left'] = '1.5em';
            if (['kbd', 'samp', 'tt', 'pre'].contains(tag)) {
              styles['font-family'] = 'monospace';
            }
            if (tag == 'caption') styles['text-align'] = 'center';
            if (tag == 'li' &&
                element.previousElementSibling?.localName == 'li') {
              styles['margin-top'] = '0.2em';
            }
            if ((tag == 'ul' || tag == 'ol') &&
                element.parent?.localName == 'li') {
              styles.addAll({'margin-top': '0.2em', 'margin-bottom': '0'});
            }
            if (tag == 'li' &&
                element.children.firstOrNull?.localName == 'input') {
              styles.addAll({
                'list-style-type': 'none',
                'margin-left': '-1.3em',
              });
            }
            if (tag == 'p' && element.parent?.localName == 'li') {
              styles['margin-bottom'] = '0.4em';
            }
            if (tag == 'code' && element.parent?.localName != 'pre') {
              styles.addAll({
                'padding': '0.12em 0.4em',
                'background-color': cssColor(colors['surface.subtle']),
                'color': cssColor(colors['text.primary']),
                'font-family': 'monospace',
                'font-size': '0.87em',
              });
            }
            if (element.classes.contains('code-block')) {
              styles.addAll({
                'background-color': cssColor(colors['web.code-bg']),
                'color': cssColor(colors['web.code-ink']),
                'border-radius': '12px',
              });
            }
            if (element.classes.contains('code-head')) {
              styles.addAll({
                'padding': '4px 6px 4px 14px',
                'border-bottom': '1px solid ${cssColor(colors['web.line'])}',
                'color': cssColor(colors['web.code-head']),
                'font-family': 'monospace',
                'font-size': '12px',
              });
            }
            if (tag == 'pre') {
              styles.addAll({
                'margin': '0',
                'padding': '12px 14px',
                'font-family': 'monospace',
                'font-size': '13px',
                'line-height': '1.6',
              });
            }
            if (tag == 'code' && element.parent?.localName == 'pre') {
              styles['font-family'] = 'monospace';
            }
            if (element.classes.contains('code-copy')) {
              styles.addAll({
                'padding': '4px 14px',
                'border': '0',
                'border-radius': '6px',
                'color': cssColor(colors['web.muted']),
                'background-color': 'transparent',
                'font-size': '12px',
                // The HTML core sizes this minimum before its 8px padding.
                'min-height': '28px',
              });
            }
            if (tag == 'table') {
              styles.addAll({
                'width': '100%',
                'border-collapse': 'collapse',
                'border-spacing': '0',
                'font-size': '0.92em',
                'line-height': '1.5',
              });
            }
            if (tag == 'th' || tag == 'td') {
              styles.addAll({
                'padding': '6px 10px',
                'border-bottom':
                    '1px solid ${cssColor(colors['line.default'])}',
                'text-align': element.attributes['align'] ?? 'left',
                'vertical-align': 'top',
                if (tag == 'th')
                  'background-color': cssColor(colors['surface.subtle']),
                if (tag == 'th') 'font-weight': '600',
              });
              final row = element.parent;
              if (tag == 'td' &&
                  row?.localName == 'tr' &&
                  row?.parent?.localName == 'tbody' &&
                  row?.nextElementSibling == null) {
                styles['border-bottom'] = '0';
              }
            }
            if (element.attributes.containsKey('hidden')) {
              styles['display'] = 'none';
            }
            // Match .markdown > :first/last-child after the HTML parser repairs it.
            if (element.parentNode is dom.DocumentFragment) {
              final siblings = element.parentNode!.nodes
                  .whereType<dom.Element>();
              if (siblings.firstOrNull == element) {
                styles['margin-top'] = '0';
              }
              if (siblings.lastOrNull == element) {
                styles['margin-bottom'] = '0';
              }
            }
            styles.addAll(nativeHtmlHighlightStyles(element, colors));
            return styles;
          },
          customWidgetBuilder: (element) {
            if (element.localName == 'input' &&
                element.attributes['data-pirc-task'] == nonce &&
                element.attributes['type'] == 'checkbox' &&
                widget.checkboxBuilder != null) {
              return InlineCustomWidget(
                child: widget.checkboxBuilder!(
                  element.attributes.containsKey('checked'),
                ),
              );
            }
            final control = controls!.resolveControl(element);
            if (control != null) {
              return InlineCustomWidget(
                child: NativeHtmlControlWidget(
                  key: controls!.widgetKeyFor(control.key),
                  state: controls!,
                  control: control,
                  accent: colors['accent.default'],
                ),
              );
            }
            final textField = textFields!.resolveControl(element);
            if (textField != null) {
              return InlineCustomWidget(
                alignment: textField.kind == NativeHtmlTextFieldKind.textarea
                    ? PlaceholderAlignment.aboveBaseline
                    : PlaceholderAlignment.baseline,
                child: NativeHtmlTextFieldWidget(
                  state: textFields!,
                  field: textField,
                  // Pinned web sets 16px controls on touch devices, including tablets.
                  textStyle: widget.style.copyWith(
                    fontSize: widget.markdownStyles ? 16 : 13.333333333333334,
                    textBaseline:
                        widget.style.textBaseline ?? TextBaseline.alphabetic,
                    fontFamily: widget.markdownStyles
                        ? widget.style.fontFamily
                        : (textField.kind == NativeHtmlTextFieldKind.textarea
                              ? 'monospace'
                              : 'sans-serif'),
                    height: widget.markdownStyles
                        ? widget.style.height
                        : kTextHeightNone,
                    letterSpacing: widget.style.letterSpacing ?? 0,
                  ),
                ),
              );
            }
            final date = dates!.resolveControl(element);
            final file = files!.resolveControl(element);
            if (date != null || file != null) {
              final style = widget.style.copyWith(
                fontSize: widget.markdownStyles ? 16 : 13.333333333333334,
                fontFamily: widget.markdownStyles
                    ? widget.style.fontFamily
                    : 'sans-serif',
                textBaseline: TextBaseline.alphabetic,
                height: widget.markdownStyles
                    ? widget.style.height
                    : kTextHeightNone,
                letterSpacing: widget.style.letterSpacing ?? 0,
              );
              return InlineCustomWidget(
                alignment: PlaceholderAlignment.baseline,
                child: date != null
                    ? NativeHtmlDateInput(
                        key: dates!.widgetKeyFor(date.key),
                        state: dates!,
                        control: date,
                        textStyle: style,
                      )
                    : NativeHtmlFileInputWidget(
                        key: files!.widgetKeyFor(file!.key),
                        strings: NativeHtmlFileInputStrings.forLocale(
                          WidgetsBinding.instance.platformDispatcher.locale,
                        ),
                        state: files!,
                        control: file,
                        textStyle: style,
                      ),
              );
            }
            final range = ranges!.resolveControl(element);
            if (range != null) {
              return InlineCustomWidget(
                child: NativeHtmlRangeWidget(
                  state: ranges!,
                  control: range,
                  focusAccent: colors['accent.default'],
                ),
              );
            }
            final select = selects!.resolveControl(element);
            if (select != null) {
              return InlineCustomWidget(
                alignment: select.multiple || select.size > 1
                    ? PlaceholderAlignment.bottom
                    : PlaceholderAlignment.baseline,
                child: NativeHtmlSelectWidget(
                  key: selects!.widgetKeyFor(select.key),
                  state: selects!,
                  control: select,
                  textStyle: widget.style.copyWith(
                    fontSize: widget.markdownStyles ? 16 : 13.333333333333334,
                    textBaseline:
                        widget.style.textBaseline ?? TextBaseline.alphabetic,
                    fontFamily: widget.markdownStyles
                        ? widget.style.fontFamily
                        : 'sans-serif',
                    height: widget.markdownStyles
                        ? widget.style.height
                        : kTextHeightNone,
                    letterSpacing: widget.style.letterSpacing ?? 0,
                  ),
                ),
              );
            }
            if (element.localName == 'svg') {
              final source = element.outerHtml;
              try {
                final size = svgImageSize(source);
                return InlineCustomWidget(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1,
                    heightFactor: 1,
                    child: SvgPicture.string(
                      source,
                      width: size.width,
                      height: size.height,
                      semanticsLabel: element.querySelector('title')?.text,
                    ),
                  ),
                );
              } catch (_) {
                return Text(tr("SVG could not be rendered"));
              }
            }
            final native = slots[element.attributes['data-pirc-native']];
            if (native == null) return null;
            final builder = widget.builders[native.tag]!;
            final built = builder.visitElementAfterWithContext(
              context,
              native,
              widget.style,
              widget.style,
            );
            if (built == null) return null;
            return builder.isBlockElement()
                ? built
                : InlineCustomWidget(child: built);
          },
          onErrorBuilder: (context, element, error) => Text(
            element.attributes['alt'] ?? tr("Content could not be rendered"),
            style: widget.style,
          ),
        ),
      ),
    );
    // Full documents scroll under unbounded vertical constraints. Publish the
    // document viewport as the root's CSS containing block without forcing the
    // content to that size. Auto-height elements still break percentage chains.
    // Markdown has no document viewport and must retain its content sizing.
    final viewport = _documentViewport;
    final documentRoot = viewport != null
        ? NativeDocumentContainingBlock(
            width: viewport.width,
            height: viewport.height,
            child: NativeDocumentElementScroll(
              controller: _elementScroll,
              id: 'pirc-document-root-$nonce',
              revision: widget.layoutRevision,
              overflowX: NativeDocumentOverflow.visible,
              overflowY: NativeDocumentOverflow.visible,
              expandVisibleOverflow: true,
              child: widget.documentPercentTopMargins.isEmpty
                  ? document
                  : NativeDocumentMarginCollapseRoot(child: document),
            ),
          )
        : document;
    return _NativeHtmlFocusScrollGate(
      suppress: _shouldSuppressFocusReveal,
      child: NativeHtmlFormFeedback(
        forms: forms!,
        child: widget.layoutController != null
            ? NativeDocumentLayoutRoot(
                controller: widget.layoutController!,
                revision: widget.layoutRevision,
                knownIds: widget.layoutKnownIds,
                noBoxIds: widget.layoutNoBoxIds,
                computedStyles: widget.layoutComputedStyles,
                child: documentRoot,
              )
            : documentRoot,
      ),
    );
  }
}

class _NativeHtmlFactory extends WidgetFactory {
  _NativeHtmlFactory(
    this.images,
    this.controls,
    this.textFields,
    this.selects,
    this.ranges,
    this.dates,
    this.files,
    this.scriptFocusableNode,
    this.detailsGroups,
    this.onDetailsActivate,
    this.buttons,
    this.forms,
    this.markdownStyles,
    this.hasDocumentViewport,
    this.hasPositioningViewport,
    this.onNavigate,
    this.onScriptTap,
    this.dark,
    this.sourceFontFallback,
    this.sourceSlots,
    this.mathBuilders,
    this.backgroundImages,
    this.mediaWidgets,
    this.canvases,
    this.canvasImages,
    this.canvasPointerSurface,
    this.canvasPointerEnabled,
    this.imageViewport,
    this.imageDpr,
    this.imageDark,
    this.layoutController,
    this.layoutOffsetSpecs,
    this.layoutComputedStyles,
    this.documentPercentTopMargins,
    this.layoutRevision,
    this.elementScroll,
    this.htmlImages,
    this.vectorImageSources,
    this.deferImageLoading,
    this.documentRuntime,
  );

  /// The document runtime, only inside a fetched or script-driven document;
  /// null for chat content, whose dialogs never leave normal flow and whose
  /// canvases stay blank.
  final DocumentRuntime? Function() documentRuntime;
  DocumentTopLayer? topLayer() => documentRuntime()?.topLayer;
  int? _topLayerOrder(dom.Element element) => topLayer()?.orderOf(element);
  bool _inTopLayer(dom.Element element) => _topLayerOrder(element) != null;
  // HtmlWidget retains its factory when rebuild triggers change. Read the
  // current document viewport instead of capturing the first build.
  final Map<String, NativeDocumentHtmlImage> Function() htmlImages;
  final Map<String, Uint8List> Function() vectorImageSources;
  final bool Function() deferImageLoading;
  final bool Function() hasDocumentViewport;
  final bool Function() hasPositioningViewport;
  final Size Function() imageViewport;
  final double Function() imageDpr;
  final bool Function() imageDark;
  final NativeDocumentLayoutController? Function() layoutController;
  final Map<String, NativeDocumentOffsetSpec> Function() layoutOffsetSpecs;
  final Map<String, NativeDocumentComputedStyleSpec> Function()
  layoutComputedStyles;
  final Map<String, NativeDocumentTopMarginGroup> Function()
  documentPercentTopMargins;
  final int Function() layoutRevision;
  final NativeDocumentElementScrollController Function() elementScroll;
  Expando<({bool enabled, bool ancestorNone})> _pointerPolicies = Expando();
  final _pointerRecognizers = <NativeDocumentPointerTapRecognizer>[];

  ({bool enabled, bool ancestorNone}) _pointerPolicy(dom.Element element) {
    final cached = _pointerPolicies[element];
    if (cached != null) return cached;
    final parent = element.parent;
    final inherited = parent == null
        ? (enabled: true, ancestorNone: false)
        : _pointerPolicy(parent);
    final value = nativeDocumentPointerValue(
      _flexChildStyles(element)['pointer-events'],
      inherited.enabled ? 'auto' : 'none',
    );
    return _pointerPolicies[element] = (
      enabled: value != 'none',
      ancestorNone: !inherited.enabled || inherited.ancestorNone,
    );
  }

  Widget _pointerBox(dom.Element element, Widget child) {
    final policy = _pointerPolicy(element);
    return policy.enabled && !policy.ancestorNone
        ? child
        : NativeDocumentPointerEvents(
            enabled: policy.enabled,
            surface: (box) => nativeDocumentBoxSurface(box, owner: element),
            child: child,
          );
  }

  bool _pointerInline(dom.Element element) {
    if (_absoluteSupported(element)) return false;
    final display = _flexChildStyles(element)['display'];
    return display == 'inline' ||
        (display == null &&
            const {
              'a',
              'span',
              'abbr',
              'b',
              'strong',
              'i',
              'em',
              'small',
              'code',
              'label',
              's',
              'u',
              'sup',
              'sub',
              'time',
              'kbd',
              'samp',
            }.contains(element.localName));
  }

  void _registerPointerEvents(BuildTree tree) {
    if (markdownStyles) return;
    final element = tree.element, policy = _pointerPolicy(tree.element);
    if (policy.enabled && !policy.ancestorNone) return;
    tree.register(
      BuildOp(
        alwaysRenderBlock: false,
        debugLabel: 'native-pointer-events',
        priority: 9000008900000000,
        onRenderBlock: (_, placeholder) => placeholder.wrapWith(
          (_, child) => NativeDocumentPointerEvents(
            enabled: policy.enabled,
            surface: (box) => nativeDocumentBoxSurface(box, owner: element),
            child: child,
          ),
        ),
        onParsed: (parsed) {
          if (!identical(parsed.element, element) ||
              parsed.isInline != true ||
              !_pointerInline(element)) {
            return parsed;
          }
          dom.Element? fallback;
          if (!policy.enabled) {
            var ancestor = element.parent;
            while (ancestor != null) {
              if (_pointerPolicy(ancestor).enabled) {
                if (_pointerInline(ancestor)) fallback = ancestor;
                break;
              }
              ancestor = ancestor.parent;
            }
          }
          final ancestorTarget = fallback;
          final restores =
              policy.enabled && policy.ancestorNone ||
              ancestorTarget != null &&
                  _pointerPolicy(ancestorTarget).ancestorNone;
          final carrier = NativeDocumentPointerTapRecognizer(
            restoresHit: restores,
          );
          _pointerRecognizers.add(carrier);
          parsed.inherit<GestureRecognizer>((resolved, _) {
            final inherited = resolved.get<GestureRecognizer>();
            carrier.onTap = policy.enabled
                ? inherited is TapGestureRecognizer
                      ? inherited.onTap
                      : null
                : ancestorTarget == null
                ? null
                : _scriptTapEnabled(ancestorTarget)
                ? () =>
                      onScriptTap!(ancestorTarget, _linkAction(ancestorTarget))
                : _linkAction(ancestorTarget);
            return resolved.copyWith<GestureRecognizer>(value: carrier);
          }, carrier);
          return parsed;
        },
      ),
    );
  }

  void _disposePointerRecognizers() {
    for (final recognizer in _pointerRecognizers) {
      recognizer.dispose();
    }
    _pointerRecognizers.clear();
  }

  @override
  void dispose() {
    _disposePointerRecognizers();
    super.dispose();
  }

  final _absoluteChildren =
      <
        dom.Element?,
        List<
          ({
            BuildTree tree,
            Widget child,
            Map<String, String> styles,
            GlobalKey? marker,
          })
        >
      >{};
  final _absolutePlaceholders = <WidgetPlaceholder>{};
  final _geometryBlockWrapped = Expando<bool>();
  final _geometryOwnSizing = Expando<bool>();
  final _imageDensities = Expando<double>();
  final Widget? Function(dom.Element) mediaWidgets;
  final Map<String, RenderCanvasSnapshot> Function() canvases;
  final Map<String, ui.Image> Function() canvasImages;
  final Widget Function(dom.Element, Widget, bool) canvasPointerSurface;
  final bool Function() canvasPointerEnabled;
  final ImageProvider? Function(String) backgroundImages;
  final MarkdownImageBuilder? images;
  final NativeHtmlControlState controls;
  final NativeHtmlTextFieldState textFields;
  final NativeHtmlSelectState selects;
  final NativeHtmlRangeState ranges;
  final NativeHtmlDateState dates;
  final NativeHtmlFileInputState files;
  final FocusNode Function(dom.Element) scriptFocusableNode;
  final NativeHtmlDetailsGroups detailsGroups;
  final ValueChanged<String>? onDetailsActivate;
  final NativeHtmlButtonState buttons;
  final NativeHtmlForms forms;
  final bool markdownStyles;
  final ValueChanged<NativeHtmlLink>? onNavigate;
  final void Function(dom.Element, VoidCallback?)? onScriptTap;
  final bool dark;
  final List<String>? sourceFontFallback;
  final Map<String, md.Element> sourceSlots;
  final Map<String, MarkdownElementBuilder> mathBuilders;
  final _buttonContents = Expando<NativeHtmlButtonDescriptor>();

  Map<WidgetBit, String?> _nativeSourceIdsFor(List<WidgetBit> bits) {
    final byParent = <BuildTree, List<WidgetBit>>{};
    for (final bit in bits) {
      byParent.putIfAbsent(bit.parent, () => []).add(bit);
    }

    final result = <WidgetBit, String?>{};
    for (final entry in byParent.entries) {
      final sourceElements = _inlineWidgetElements(entry.key.element);
      // The HTML core does not retain the source DOM element on WidgetBit.
      // Associate IDs only when its inline-widget stream has the same exact
      // cardinality as the source elements in DOM order. Ambiguous trees stay
      // untouched instead of risking a control or image replacement.
      if (sourceElements.length != entry.value.length) continue;
      for (var index = 0; index < sourceElements.length; index++) {
        result[entry.value[index]] =
            sourceElements[index].attributes['data-pirc-native'];
      }
    }
    return result;
  }

  dom.Element? _htmlAnchorFor(dom.Element element) {
    dom.Node? current = element;
    while (current is dom.Element) {
      if (current.localName == 'a') return current;
      current = current.parentNode;
    }
    return null;
  }

  bool _sameInlineMathTextStyle(TextStyle left, TextStyle right) =>
      left.fontSize == right.fontSize &&
      left.color == right.color &&
      left.fontWeight == right.fontWeight &&
      left.fontStyle == right.fontStyle &&
      left.fontFamily == right.fontFamily;

  bool _canRelaxInlineReplacedWidth(BuildTree tree) {
    // Percentages and deferred expressions need the original containing-block
    // constraints. RichText's replaced-element path relaxes both inline axes,
    // so retain normal paragraph constraints whenever one of these lengths
    // could depend on that containing block.
    for (final property in const [
      'width',
      'height',
      'min-width',
      'max-width',
      'min-height',
      'max-height',
      'margin',
      'margin-top',
      'margin-right',
      'margin-bottom',
      'margin-left',
      'padding',
      'padding-top',
      'padding-right',
      'padding-bottom',
      'padding-left',
    ]) {
      final expression = tree.getStyle(property)?.expression;
      if (expression == null) continue;
      final printer = css.CssPrinter();
      expression.visit(printer);
      final value = printer.toString().trim().toLowerCase();
      if (value.isEmpty) continue;
      if (value == 'inherit') return false;
      if (value.contains('%') ||
          value.contains('calc(') ||
          value.contains('var(') ||
          value.contains('min(') ||
          value.contains('max(') ||
          value.contains('clamp(')) {
        return false;
      }
      for (final token in value.split(RegExp(r'\s+'))) {
        if (const {
          'auto',
          'none',
          'initial',
          'inherit',
          'unset',
          'revert',
          'revert-layer',
        }.contains(token)) {
          continue;
        }
        if (_flexLength(token, 16) == null) return false;
      }
    }
    return true;
  }

  bool _hasRawInlineReplacedElement(dom.Element element) =>
      const {'img', 'canvas'}.contains(element.localName) ||
      element.querySelector('img, canvas') != null;

  List<dom.Element> _inlineWidgetElements(dom.Element root) {
    bool isInlineWidget(dom.Element element) {
      final sourceId = element.attributes['data-pirc-native'];
      if (sourceId != null) {
        final source = sourceSlots[sourceId];
        final builder = source == null ? null : mathBuilders[source.tag];
        return builder != null && !builder.isBlockElement();
      }
      return const {
        'audio',
        'button',
        'canvas',
        'img',
        'input',
        'select',
        'svg',
        'textarea',
        'video',
      }.contains(element.localName);
    }

    final result = <dom.Element>[];
    if (isInlineWidget(root)) result.add(root);
    for (final element in root.querySelectorAll('*')) {
      if (isInlineWidget(element)) result.add(element);
    }
    return result;
  }

  bool _scriptTapEnabled(dom.Element element) {
    if (onScriptTap == null ||
        !element.attributes.containsKey('data-pirc-script-id')) {
      return false;
    }
    if (element.localName == 'canvas' && canvasPointerEnabled()) return false;
    // Native controls already own their gesture and default-action pipelines.
    for (
      dom.Element? current = element;
      current != null;
      current = current.parent
    ) {
      if (const {
        'button',
        'input',
        'select',
        'textarea',
        'audio',
        'video',
      }.contains(current.localName)) {
        return false;
      }
    }
    return element.attributes.containsKey('data-pirc-script-click') ||
        (element.localName == 'a' && element.attributes.containsKey('href'));
  }

  VoidCallback? _linkAction(dom.Element element) {
    final href = element.attributes['href'];
    if (element.localName != 'a' || href == null || onNavigate == null) {
      return null;
    }
    return () => onNavigate!(
      NativeHtmlLink(
        href,
        target: element.attributes['target'] ?? '',
        download: element.attributes['download'],
        referrerPolicy: element.attributes['referrerpolicy'],
        noopener: nativeHtmlNoopener(element.attributes['rel']),
        noreferrer: (element.attributes['rel'] ?? '')
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .contains('noreferrer'),
        targetSpecified: element.attributes.containsKey('target'),
      ),
    );
  }

  @override
  Widget? buildGestureDetector(
    BuildTree tree,
    Widget child,
    GestureRecognizer recognizer,
  ) {
    if (!markdownStyles &&
        tree.isInline != true &&
        recognizer is TapGestureRecognizer) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: recognizer.onTap,
          child: child,
        ),
      );
    }
    return super.buildGestureDetector(tree, child, recognizer);
  }

  @override
  GestureRecognizer? buildGestureRecognizer(
    BuildTree tree, {
    GestureTapCallback? onTap,
  }) {
    final fallback = _linkAction(tree.element) ?? onTap;
    final summary = nativeHtmlDetailsSummaryFor(tree.element);
    final focusNode =
        _scriptFocusNodeForElement(tree.element) ??
        (summary?.attributes.containsKey('data-pirc-script-id') == true
            ? scriptFocusableNode(summary!)
            : null);
    void focusBeforeTap() {
      if (focusNode == null || !focusNode.canRequestFocus) return;
      focusNode.requestFocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
    }

    return super.buildGestureRecognizer(
      tree,
      onTap: _scriptTapEnabled(tree.element)
          ? () {
              focusBeforeTap();
              onScriptTap!(tree.element, fallback);
            }
          : fallback == null
          ? null
          : () {
              focusBeforeTap();
              fallback();
            },
    );
  }

  FocusNode? _scriptFocusNodeForElement(dom.Element element) {
    final id = element.attributes['data-pirc-script-id'];
    final anchor =
        element.localName == 'a' && element.attributes.containsKey('href');
    final tabIndex = int.tryParse(element.attributes['tabindex'] ?? '');
    final summary = nativeHtmlDetailsSummaryFor(element) == element;
    final dialog = element.localName == 'dialog';
    if (id == null || (!anchor && !summary && !dialog && tabIndex == null)) {
      return null;
    }
    if (controls.resolveControl(element) != null ||
        textFields.resolveControl(element) != null ||
        selects.resolveControl(element) != null ||
        ranges.resolveControl(element) != null ||
        dates.resolveControl(element) != null ||
        files.resolveControl(element) != null ||
        buttons.resolveControl(element) != null) {
      return null;
    }
    return scriptFocusableNode(element);
  }

  void _registerScriptFocus(BuildTree tree) {
    // The details replacement attaches this node to its activation surface.
    if (nativeHtmlDetailsSummaryFor(tree.element) == tree.element) return;
    if (_absoluteSupported(tree.element)) return;
    final focusNode = _scriptFocusNodeForElement(tree.element);
    if (focusNode == null) return;
    final display = tree.getStyle('display')?.term?.toString();
    final inline =
        display?.startsWith('inline') ??
        const {
          'a',
          'abbr',
          'b',
          'code',
          'em',
          'i',
          'label',
          'small',
          'span',
          'strong',
          'sub',
          'sup',
          'time',
        }.contains(tree.element.localName);
    Widget wrap(BuildContext context, Widget child) =>
        Focus(focusNode: focusNode, child: child);
    if (inline) {
      tree.register(
        BuildOp.inline(
          debugLabel: 'native-script-focus-inline',
          onRenderInlineBlock: (_, child) =>
              Focus(focusNode: focusNode, child: child),
        ),
      );
    } else {
      tree.register(
        BuildOp(
          debugLabel: 'native-script-focus-block',
          onRenderedBlock: (_, block) {
            (block as WidgetPlaceholder).wrapWith(wrap);
          },
        ),
      );
    }
  }

  bool _hasNativeLabelTarget(dom.Element element) =>
      controls.resolveLabel(element) != null ||
      textFields.resolveLabel(element) != null ||
      selects.resolveLabel(element) != null ||
      buttons.resolveLabel(element) != null ||
      ranges.resolveLabel(element) != null ||
      dates.resolveLabel(element) != null ||
      files.resolveLabel(element) != null;

  void _registerScriptTap(BuildTree tree) {
    if (!_scriptTapEnabled(tree.element) ||
        (tree.element.localName == 'label' &&
            _hasNativeLabelTarget(tree.element)) ||
        (tree.element.localName == 'a' &&
            tree.element.attributes.containsKey('href'))) {
      return;
    }
    tree.register(
      BuildOp(
        alwaysRenderBlock: false,
        debugLabel: 'native-script-click',
        onParsed: (parsed) {
          final recognizer = buildGestureRecognizer(parsed);
          if (recognizer == null) return parsed;
          if (parsed.isInline == true) {
            for (final bit in parsed.bits) {
              if (bit is WidgetBit) {
                bit.child.wrapWith(
                  (context, child) =>
                      buildGestureDetector(parsed, child, recognizer),
                );
              }
            }
          }
          parsed.inherit<GestureRecognizer>(
            (resolved, value) =>
                resolved.copyWith<GestureRecognizer>(value: value),
            recognizer,
          );
          parsed.setNonInherited<GestureRecognizer>(recognizer);
          return parsed;
        },
      ),
    );
    tree.register(
      BuildOp(
        alwaysRenderBlock: false,
        debugLabel: 'native-script-click-border-box',
        // Keep measurement outside the opaque detector so empty CSS surfaces
        // retain their own DOM hit identity, including transparent padding.
        priority: 5000005740000000,
        onRenderBlock: (parsed, placeholder) {
          final recognizer = parsed.getNonInherited<GestureRecognizer>();
          if (recognizer != null) {
            placeholder.wrapWith(
              (context, child) =>
                  buildGestureDetector(parsed, child, recognizer),
            );
          }
          return placeholder;
        },
      ),
    );
  }

  Widget _measureLayoutElement(
    dom.Element element,
    Widget child, {
    bool controlSurface = false,
  }) {
    final controller = layoutController();
    final id = element.attributes['data-pirc-script-id'];
    if (controller == null || id == null) return child;
    return NativeDocumentLayoutElement(
      controller: controller,
      revision: layoutRevision(),
      id: id,
      offsetSpec: layoutOffsetSpecs()[id],
      boxSurface: !controlSurface && _geometryOwnSizing[element] == true
          ? (box) => nativeDocumentBoxSurface(box, owner: element)
          : null,
      child: child,
    );
  }

  @override
  Widget? customWidgetBuilder(dom.Element element) {
    // Positioned replacements need their full CSS box before extraction.
    if (_absoluteSupported(element)) return null;
    final built = _customWidgetForElement(element);
    if (built == null) return null;
    if (built is InlineCustomWidget) {
      return InlineCustomWidget(
        alignment: built.alignment,
        baseline: built.baseline,
        child: _pointerBox(
          element,
          _measureLayoutElement(element, built.child),
        ),
      );
    }
    return _pointerBox(element, _measureLayoutElement(element, built));
  }

  NativeHtmlControlDescriptor? _styledToggle(dom.Element element) {
    if (markdownStyles) return null;
    final control = controls.resolveControl(element);
    if (control == null) return null;
    final styles = _flexChildStyles(element);
    return styles.keys.any(
          (key) =>
              const {
                'width',
                'height',
                'min-width',
                'min-height',
                'max-width',
                'max-height',
                'box-sizing',
                'margin',
              }.contains(key) ||
              key.startsWith('margin-') ||
              key.startsWith('padding') ||
              key.startsWith('border'),
        )
        ? control
        : null;
  }

  Widget? _customWidgetForElement(dom.Element element) {
    if (element.localName == 'audio' || element.localName == 'video') {
      final media = mediaWidgets(element);
      if (media != null) {
        return InlineCustomWidget(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: NativeHtmlInlineOverflowHost(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              heightFactor: 1,
              child: media,
            ),
          ),
        );
      }
    }
    if (!markdownStyles &&
        (_styledToggle(element) != null ||
            textFields.resolveControl(element) != null ||
            selects.resolveControl(element) != null ||
            dates.resolveControl(element) != null ||
            files.resolveControl(element) != null)) {
      // A prebuilt WidgetSpan bypasses this element's own CSS/inheritance tree.
      // Raw document controls instead enter parse() and keep their native state.
      return null;
    }
    final built = super.customWidgetBuilder(element);
    if (built is InlineCustomWidget &&
        const {'input', 'textarea', 'select'}.contains(element.localName)) {
      // A sole widget inside a block can receive its parent's tight width from
      // the HTML core. The native control still owns its intrinsic border box.
      final anchor = forms.anchorFor(element);
      final anchoredChild = anchor == null
          ? built.child
          : KeyedSubtree(key: anchor, child: built.child);
      final controlChild = files.resolveControl(element) == null
          ? anchoredChild
          : NativeHtmlInlineOverflowHost(child: anchoredChild);
      return InlineCustomWidget(
        alignment: built.alignment,
        baseline: built.baseline,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          heightFactor: 1,
          child:
              controls.resolveControl(element) != null ||
                  ranges.resolveControl(element) != null
              ? NativeHtmlReplacedBaseline(child: controlChild)
              : controlChild,
        ),
      );
    }
    if (built != null && _scriptTapEnabled(element)) {
      Widget clickable(Widget child) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onScriptTap!(element, _linkAction(element)),
          child: child,
        ),
      );
      // Custom image/SVG/math widgets bypass BuildTree parsing entirely.
      // Keep their original inline alignment while restoring the actual target.
      if (built is InlineCustomWidget) {
        return InlineCustomWidget(
          alignment: built.alignment,
          baseline: built.baseline,
          child: clickable(built.child),
        );
      }
      return clickable(built);
    }
    return built;
  }

  double _cssNumber(css.Expression? value, double fallback) {
    if (value is css.Expressions && value.expressions.length == 1) {
      value = value.expressions.single;
    }
    if (value is css.LiteralTerm) {
      return double.tryParse('${value.value}') ?? fallback;
    }
    return fallback;
  }

  double _layoutLength(
    BuildTree tree,
    String property,
    InheritedProperties resolved, [
    double fallback = 0,
  ]) {
    final value = tree.getStyle(property)?.value;
    if (value is css.UnitTerm) {
      final number = _cssNumber(value, fallback);
      return switch (value.unitToString()) {
        'px' => number,
        'em' => number * (resolved.get<TextStyle>()?.fontSize ?? 16),
        'pt' => number * 96 / 72,
        _ => fallback,
      };
    }
    return _cssNumber(value, fallback);
  }

  NativeFlexLength? _flexLength(String? source, double fontSize) {
    final match = RegExp(
      r'^([+]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))(px|%|em|pt|vw|vh|vmin|vmax)?$',
    ).firstMatch(source?.trim().toLowerCase() ?? '');
    if (match == null) return null;
    final value = double.parse(match[1]!);
    if (!value.isFinite || (match[2] == null && value != 0)) return null;
    final unit = match[2];
    if (const {'vw', 'vh', 'vmin', 'vmax'}.contains(unit)) {
      final viewport = imageViewport();
      final basis = switch (unit) {
        'vw' => viewport.width,
        'vh' => viewport.height,
        'vmin' => min(viewport.width, viewport.height),
        _ => max(viewport.width, viewport.height),
      };
      final pixels = value / 100 * basis;
      return pixels.isFinite && pixels >= 0
          ? NativeFlexLength.pixels(pixels)
          : null;
    }
    return switch (unit) {
      '%' => NativeFlexLength.percent(value),
      'em' => NativeFlexLength.pixels(value * fontSize),
      'pt' => NativeFlexLength.pixels(value * 96 / 72),
      _ => NativeFlexLength.pixels(value),
    };
  }

  Map<String, String> _flexChildStyles(dom.Element element) {
    final styles = <String, String>{};
    final parsed = css_parser.parse('*{${element.attributes['style'] ?? ''}}');
    for (final rule in parsed.topLevels.whereType<css.RuleSet>()) {
      for (final declaration
          in rule.declarationGroup.declarations.whereType<css.Declaration>()) {
        final printer = css.CssPrinter();
        declaration.expression?.visit(printer);
        styles[declaration.property] = printer.toString().trim();
      }
    }
    styles.addAll(customStylesBuilder(element) ?? {});
    return styles;
  }

  CrossAxisAlignment? _flexAlign(String? value) => switch (value) {
    'center' => CrossAxisAlignment.center,
    'flex-start' || 'start' => CrossAxisAlignment.start,
    'flex-end' || 'end' => CrossAxisAlignment.end,
    'stretch' || 'normal' => CrossAxisAlignment.stretch,
    _ => null,
  };

  NativeFlexItem _flexItem(
    dom.Element element,
    bool horizontal,
    double fontSize,
  ) {
    final styles = _flexChildStyles(element);
    NativeFlexLength? length(String key) => _flexLength(styles[key], fontSize);
    double edge(String key) {
      if (key.startsWith('border-')) {
        final keyword = switch (styles[key]) {
          'thin' => 1.0,
          'medium' => 3.0,
          'thick' => 5.0,
          _ => null,
        };
        if (keyword != null) return keyword;
      }
      return length(key)?.resolve(null) ?? 0;
    }

    double edges(List<String> sides) => sides.fold<double>(
      0,
      (sum, side) =>
          sum +
          edge('padding-$side') +
          (styles['border-$side-style'] == null ||
                  const {
                    'none',
                    'hidden',
                  }.contains(styles['border-$side-style'])
              ? 0
              : edge('border-$side-width')),
    );
    double margins(List<String> sides) {
      if (!hasDocumentViewport()) return 0;
      return sides.fold<double>(0, (sum, side) {
        final value = styles['margin-$side']?.trim() ?? '';
        final negative = value.startsWith('-');
        final pixels =
            _flexLength(
              negative ? value.substring(1) : value,
              fontSize,
            )?.resolve(null) ??
            0;
        return sum + (negative ? -pixels : pixels);
      });
    }

    double marginPercentage(List<String> sides) {
      if (!hasDocumentViewport()) return 0;
      return sides.fold<double>(0, (sum, side) {
        final value = styles['margin-$side']?.trim() ?? '';
        final negative = value.startsWith('-');
        if (negative) {
          return sum; // Signed percentage insets need physical support.
        }
        final length = _flexLength(
          negative ? value.substring(1) : value,
          fontSize,
        );
        if (length == null || !length.percentage) return sum;
        return sum + (negative ? -1 : 1) * length.value / 100;
      });
    }

    final main = horizontal ? 'width' : 'height';
    final cross = horizontal ? 'height' : 'width';
    final overflow =
        styles[horizontal ? 'overflow-x' : 'overflow-y'] ?? styles['overflow'];
    double factor(String key, double fallback) {
      final value = double.tryParse(styles[key] ?? '');
      return value != null && value.isFinite && value >= 0 ? value : fallback;
    }

    return NativeFlexItem(
      grow: factor('flex-grow', 0),
      shrink: factor('flex-shrink', 1),
      basis: length('flex-basis'),
      preferredMain: length(main),
      preferredCross: length(cross),
      minimumMain: length('min-$main'),
      maximumMain: length('max-$main'),
      minimumCross: length('min-$cross'),
      maximumCross: length('max-$cross'),
      automaticMinimum: !const {'hidden', 'auto', 'scroll'}.contains(overflow),
      mainEdges: edges(horizontal ? ['left', 'right'] : ['top', 'bottom']),
      crossEdges: edges(horizontal ? ['top', 'bottom'] : ['left', 'right']),
      mainMargins: margins(horizontal ? ['left', 'right'] : ['top', 'bottom']),
      crossMargins: margins(horizontal ? ['top', 'bottom'] : ['left', 'right']),
      mainMarginPercentage: marginPercentage(
        horizontal ? ['left', 'right'] : ['top', 'bottom'],
      ),
      crossMarginPercentage: marginPercentage(
        horizontal ? ['top', 'bottom'] : ['left', 'right'],
      ),
      borderBox: _documentUsesBorderBox(element),
      stretchCross: length(cross) == null,
      align: _flexAlign(styles['align-self']),
      order: int.tryParse(styles['order'] ?? '') ?? 0,
    );
  }

  double _fixedMargin(
    Map<String, String> styles,
    String side,
    double fontSize,
  ) {
    final value = styles['margin-$side']?.trim() ?? '0';
    final negative = value.startsWith('-');
    final pixels =
        _flexLength(
          negative ? value.substring(1) : value,
          fontSize,
        )?.resolve(null) ??
        0;
    return negative ? -pixels : pixels;
  }

  bool _ownsFixedFlexMargins(dom.Element element) {
    if (!hasDocumentViewport() || !_directDocumentFlexItem(element)) {
      return false;
    }
    final styles = _flexChildStyles(element);
    const sides = ['left', 'top', 'right', 'bottom'];
    if (!sides.any((side) => styles.containsKey('margin-$side'))) return false;
    return sides.every((side) {
      final value = styles['margin-$side']?.trim() ?? '0';
      final length = _flexLength(
        value.startsWith('-') ? value.substring(1) : value,
        16,
      );
      return length != null && !length.percentage;
    });
  }

  bool _documentUsesBorderBox(dom.Element element) {
    dom.Element? current = element;
    while (current != null) {
      final value = _flexChildStyles(current)['box-sizing'];
      if (value != 'inherit') return value == 'border-box';
      current = current.parent;
    }
    return false;
  }

  bool _directDocumentFlexItem(dom.Element element) {
    final parent = element.parent;
    return parent != null && _flexChildStyles(parent)['display'] == 'flex';
  }

  bool _directDocumentGridItem(dom.Element element) {
    final parent = element.parent;
    return parent != null && _flexChildStyles(parent)['display'] == 'grid';
  }

  String _elementScrollId(dom.Element element) {
    final scriptId = element.attributes['data-pirc-script-id'];
    if (scriptId != null) return scriptId;
    final styleKey = element.attributes['data-pirc-document-style'];
    if (styleKey != null) return 'native-static-$styleKey';
    final path = <int>[];
    dom.Element? current = element;
    while (current?.parent != null) {
      path.add(current!.parent!.children.indexOf(current));
      current = current.parent;
    }
    return 'native-static-${path.reversed.join('-')}';
  }

  // Core cannot resolve an inline percentage height against the definite native
  // containing block. Keep this path alongside owned border-box sizing.
  bool _ownsInlineReplacedSizing(BuildTree tree) =>
      !markdownStyles &&
      const {'img', 'canvas'}.contains(tree.element.localName) &&
      !const {'block', 'flex', 'grid', 'flow-root'}.contains(
        _flexChildStyles(tree.element)['display']?.trim().toLowerCase(),
      ) &&
      (_documentUsesBorderBox(tree.element) ||
          (tree.element.localName == 'canvas' &&
              (_flexChildStyles(tree.element)['height']?.trim().endsWith('%') ??
                  false)));

  Expando<bool> _absoluteSupport = Expando<bool>();
  @override
  void reset(State state) {
    _disposePointerRecognizers();
    _pointerPolicies = Expando();
    _absoluteChildren.clear();
    _absolutePlaceholders.clear();
    _absoluteSupport = Expando<bool>();
    super.reset(state);
  }

  bool _absoluteSupported(dom.Element element) =>
      _absoluteSupport[element] ??= _calculateAbsoluteSupport(element);

  bool _positioningBlock(dom.Element element) {
    final styles = _flexChildStyles(element);
    if (const {'absolute', 'fixed'}.contains(styles['position'])) return true;
    final display =
        styles['display'] ??
        (const {
              'div',
              'section',
              'article',
              'main',
              'header',
              'footer',
              'form',
              'html',
              'body',
              'nav',
              'aside',
            }.contains(element.localName)
            ? 'block'
            : 'inline');
    return const {'block', 'flex', 'grid', 'flow-root'}.contains(display);
  }

  bool _transformContainingBlock(dom.Element element) {
    final css = _flexChildStyles(element);
    return !markdownStyles &&
        _positioningBlock(element) &&
        const {
          '',
          'view-box',
          'border-box',
        }.contains(css['transform-box'] ?? '') &&
        NativeDocumentTransformSpec.parse(
              css['transform'],
              origin: css['transform-origin'],
            ) !=
            null;
  }

  bool _calculateAbsoluteSupport(dom.Element element) {
    if (markdownStyles) return false;
    final styles = _flexChildStyles(element);
    final spec = NativeAbsolutePositionSpec.parse(
      styles,
      fontSize: 16,
      viewport: imageViewport(),
      allowStaticPosition: true,
      topLayer: _inTopLayer(element),
    );
    if (spec == null ||
        (spec.needsStaticPosition &&
            !nativeDocumentStaticBlockPositionSupported(
              element,
              _flexChildStyles,
            ))) {
      return false;
    }
    final fixed = spec.fixedToViewport, host = _absoluteHost(element);
    final viewportFixed = fixed && host == null;
    if (viewportFixed &&
        (!hasDocumentViewport() || !hasPositioningViewport())) {
      return false;
    }
    dom.Element? current = element;
    while (current != null) {
      final css = _flexChildStyles(current);
      final supportedTransform = identical(current, element)
          ? NativeDocumentTransformSpec.parse(
                  css['transform'],
                  origin: css['transform-origin'],
                ) !=
                null
          : _transformContainingBlock(current);
      if (!supportedTransform &&
          !const {'none', ''}.contains(css['transform'] ?? '')) {
        return false;
      }
      if (!const {
        '',
        'view-box',
        'border-box',
      }.contains(css['transform-box'] ?? '')) {
        return false;
      }
      if (const [
        'translate',
        'rotate',
        'scale',
        'perspective',
        'contain',
        'filter',
        'backdrop-filter',
      ].any(
        (name) =>
            !const {'none', 'normal', 'auto', ''}.contains(css[name] ?? ''),
      )) {
        return false;
      }
      // Viewport routing crosses all ancestors. A local fixed box only crosses
      // the path below its real containing block; that block stays in the paint
      // tree with its transform, opacity and enclosing clips.
      if (fixed && (viewportFixed || current != host)) {
        if (css['display'] == 'none' ||
            current.attributes.containsKey('hidden') ||
            !const {
              'visible',
              'initial',
              'inherit',
              'unset',
            }.contains(css['visibility'] ?? 'visible') ||
            !const {'none', ''}.contains(css['clip-path'] ?? '') ||
            !const {'none', ''}.contains(css['mask'] ?? '') ||
            !const {'auto', ''}.contains(css['will-change'] ?? '') ||
            !const {'visible', ''}.contains(css['content-visibility'] ?? '') ||
            !const {'normal', ''}.contains(css['container-type'] ?? '')) {
          return false;
        }
        if (current != element) {
          final position = css['position'] ?? 'static',
              itemParent = current.parent;
          final itemDisplay = itemParent == null
              ? null
              : _flexChildStyles(itemParent)['display'];
          if (const {'fixed', 'sticky'}.contains(position) ||
              (double.tryParse(css['opacity'] ?? '1') ?? 1) != 1 ||
              !const {'normal', ''}.contains(css['mix-blend-mode'] ?? '') ||
              css['isolation'] == 'isolate' ||
              (!const {'auto', ''}.contains(css['z-index'] ?? '') &&
                  (position != 'static' ||
                      const {
                        'flex',
                        'grid',
                        'inline-flex',
                        'inline-grid',
                      }.contains(itemDisplay)))) {
            return false;
          }
        }
      }
      if (current == host) {
        final position = css['position'] ?? 'static';
        if (!const {
          'static',
          'relative',
          'absolute',
          'fixed',
        }.contains(position)) {
          return false;
        }
        if (const {'absolute', 'fixed'}.contains(position) &&
            !_absoluteSupported(current)) {
          return false;
        }
        if (position == 'relative' &&
            NativeDocumentRelativePositionSpec.parse(
                  css,
                  computedLengths:
                      layoutComputedStyles()[current
                              .attributes['data-pirc-script-id']]
                          ?.lengths ??
                      const {},
                ) ==
                null) {
          return false;
        }
        if (!_positioningBlock(current)) return false;
        return true;
      }
      current = current.parent;
    }
    return true;
  }

  dom.Element? _absoluteHost(dom.Element element) {
    if (_inTopLayer(element)) {
      // A top-layer dialog's containing block is the initial containing
      // block, even when its DOM parent is positioned or transformed.
      return null;
    }
    final fixed = _flexChildStyles(element)['position'] == 'fixed';
    var current = element.parent;
    while (current != null) {
      if (_transformContainingBlock(current) ||
          (!fixed &&
              (_flexChildStyles(current)['position'] ?? 'static') !=
                  'static')) {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  Map<String, String> _positionedStyles(
    BuildTree tree,
    Map<String, String> styles,
  ) {
    if (buttons.resolveControl(tree.element) == null) return styles;
    // The author cascade does not include UA button box defaults. Positioning
    // must use the same padding/border floor and border-box size as its native
    // control, including zero/min/max authored dimensions.
    return {
      'box-sizing': 'border-box',
      'padding-left': '6px',
      'padding-right': '6px',
      'padding-top': '1px',
      'padding-bottom': '1px',
      for (final side in ['left', 'right', 'top', 'bottom']) ...{
        'border-$side-width': '2px',
        'border-$side-style': 'solid',
      },
      ...styles,
      if (styles['box-sizing'] == 'inherit')
        'box-sizing': _documentUsesBorderBox(tree.element)
            ? 'border-box'
            : 'content-box',
    };
  }

  List<NativeAbsoluteEntry> _absoluteEntries(
    BuildContext context,
    dom.Element? host,
  ) => [
    for (final item in _absoluteChildren[host] ?? const [])
      NativeAbsoluteEntry(
        isModal: _inTopLayer(item.tree.element),
        modalOrder: _topLayerOrder(item.tree.element) ?? 0,
        spec: NativeAbsolutePositionSpec.parse(
          _positionedStyles(item.tree, item.styles),
          fontSize:
              item.tree.inheritanceResolvers
                  .resolve(context)
                  .get<TextStyle>()
                  ?.fontSize ??
              16,
          direction:
              item.tree.inheritanceResolvers
                  .resolve(context)
                  .get<TextDirection>() ??
              Directionality.of(context),
          viewport: imageViewport(),
          fixedUsesViewport: host == null,
          allowStaticPosition: item.marker != null,
          topLayer: _inTopLayer(item.tree.element),
        )!,
        child: _inTopLayer(item.tree.element)
            ? topLayer()!.scope(item.child)
            : item.child,
        staticMarker: item.marker,
        overflowHitTest: nativeDocumentRestorePointerHit,
      ),
  ];

  void _registerAbsolutePositioning(BuildTree tree) {
    final styles = _flexChildStyles(tree.element);
    // Positioned and transformed block surfaces own the padding-box basis.
    if (_transformContainingBlock(tree.element) ||
        const {'relative', 'absolute', 'fixed'}.contains(styles['position'])) {
      tree.register(
        BuildOp(
          alwaysRenderBlock: false,
          debugLabel: 'native-absolute-containing-block',
          priority: 5000005600000000,
          onRenderBlock: (parsed, placeholder) => placeholder.wrapWith((
            context,
            child,
          ) {
            final entries = _absoluteEntries(context, parsed.element);
            if (entries.isEmpty || _ownsPositioningScrollport(styles)) {
              return child;
            }
            final font =
                parsed.inheritanceResolvers
                    .resolve(context)
                    .get<TextStyle>()
                    ?.fontSize ??
                16;
            double edge(String side) =>
                const {
                  'none',
                  'hidden',
                }.contains(styles['border-$side-style'] ?? 'none')
                ? 0
                : _flexLength(
                        styles['border-$side-width'] ?? '3px',
                        font,
                      )?.resolve(null) ??
                      0;
            return NativeDocumentAbsoluteLayer(
              flow: child,
              positioned: entries,
              border: EdgeInsets.fromLTRB(
                edge('left'),
                edge('top'),
                edge('right'),
                edge('bottom'),
              ),
              boxSurface: (box) =>
                  nativeDocumentPositioningSurface(box, owner: parsed.element),
            );
          }),
        ),
      );
    }
    if (!_absoluteSupported(tree.element)) return;
    final markerSpec = NativeAbsolutePositionSpec.parse(
      styles,
      fontSize: 16,
      viewport: imageViewport(),
      allowStaticPosition: true,
      topLayer: _inTopLayer(tree.element),
    )!;
    final marker = markerSpec.needsStaticPosition ? GlobalKey() : null;
    tree.register(
      BuildOp(
        alwaysRenderBlock: true,
        debugLabel: 'native-absolute-extract',
        priority: 9000009000000000,
        onParsed: (parsed) {
          // Extract before the parent flattens flow. Definite insets remove the
          // flow bit; accepted static axes retain a zero-size block marker.
          parsed.build();
          final replacement = parsed.parent.sub();
          if (marker != null) {
            replacement.append(
              WidgetBit.block(
                replacement,
                SizedBox(key: marker, width: 0, height: 0),
              ),
            );
          }
          return replacement;
        },
        onRenderBlock: (parsed, placeholder) {
          final focus = _scriptFocusNodeForElement(parsed.element);
          _absoluteChildren
              .putIfAbsent(_absoluteHost(parsed.element), () => [])
              .add((
                tree: parsed,
                child: focus == null
                    ? placeholder
                    : Focus(focusNode: focus, child: placeholder),
                styles: styles,
                marker: marker,
              ));
          final empty = WidgetPlaceholder(child: widget0);
          _absolutePlaceholders.add(empty);
          return empty;
        },
      ),
    );
  }

  bool _ownsPositioningScrollport(Map<String, String> styles) => const [
    'overflow',
    'overflow-x',
    'overflow-y',
  ].any((name) => !const {'visible', ''}.contains(styles[name] ?? ''));

  void _documentSizing(BuildTree tree, {bool inlineReplaced = false}) {
    const properties = [
      'width',
      'height',
      'min-width',
      'max-width',
      'min-height',
      'max-height',
    ];
    final authored = <String, String>{};
    for (final property in properties) {
      final declaration = tree.getStyle(property);
      if (declaration == null) continue;
      final printer = css.CssPrinter();
      declaration.expression?.visit(printer);
      authored[property] = printer.toString().trim();
    }
    if (inlineReplaced) {
      // parse() precedes the core style pass. Read the winning author map
      // directly instead of caching an incomplete BuildTree style view.
      final inlineStyles = _flexChildStyles(tree.element);
      for (final property in properties) {
        if (inlineStyles.containsKey(property)) {
          authored[property] = inlineStyles[property]!;
        }
      }
      // The core image/canvas defaults are registered after parse() begins.
      // Preserve image HTML dimensions when no author declaration overrides them.
      // Canvas bitmap attributes supply natural dimensions through its renderer;
      // treating them as CSS lengths would defeat auto-axis aspect ratios.
      for (final property in const ['width', 'height']) {
        final attribute = int.tryParse(tree.element.attributes[property] ?? '');
        if (tree.element.localName == 'img' &&
            !authored.containsKey(property) &&
            attribute != null &&
            attribute >= 0) {
          authored[property] = '${attribute}px';
        }
      }
    }
    final styles = _flexChildStyles(tree.element);
    final absolute = _absoluteSupported(tree.element);
    double fraction(String side, [String property = 'padding']) {
      final length = _flexLength(styles['$property-$side'], 16);
      return length != null && length.percentage ? length.value / 100 : 0;
    }

    final padding = EdgeInsets.fromLTRB(
      fraction('left'),
      fraction('top'),
      fraction('right'),
      fraction('bottom'),
    );
    final margin = EdgeInsets.fromLTRB(
      fraction('left', 'margin'),
      fraction('top', 'margin'),
      fraction('right', 'margin'),
      fraction('bottom', 'margin'),
    );
    final shorthand = (styles['overflow'] ?? '').trim().toLowerCase().split(
      RegExp(r'\s+'),
    );
    final rawX = styles['overflow-x'] == null && shorthand.isNotEmpty
        ? shorthand.first
        : styles['overflow-x'];
    final rawY = styles['overflow-y'] == null && shorthand.isNotEmpty
        ? shorthand.length > 1
              ? shorthand[1]
              : shorthand.first
        : styles['overflow-y'];
    final x = NativeDocumentOverflow.values.firstWhere(
      (v) => v.name == rawX,
      orElse: () => NativeDocumentOverflow.visible,
    );
    final y = NativeDocumentOverflow.values.firstWhere(
      (v) => v.name == rawY,
      orElse: () => NativeDocumentOverflow.visible,
    );
    NativeDocumentOverflow computed(
      NativeDocumentOverflow value,
      NativeDocumentOverflow other,
    ) =>
        !const {
          NativeDocumentOverflow.visible,
          NativeDocumentOverflow.clip,
        }.contains(other)
        ? switch (value) {
            NativeDocumentOverflow.visible => NativeDocumentOverflow.auto,
            NativeDocumentOverflow.clip => NativeDocumentOverflow.hidden,
            _ => value,
          }
        : value;
    final scrollId = _elementScrollId(tree.element);
    tree.register(
      BuildOp(
        debugLabel: 'native-document-element-scroll',
        alwaysRenderBlock: false,
        priority: 5000003800000000,
        onRenderBlock: (_, placeholder) =>
            placeholder.wrapWith((context, child) {
              final entries = _ownsPositioningScrollport(styles)
                  ? _absoluteEntries(context, tree.element)
                  : const <NativeAbsoluteEntry>[];
              return NativeDocumentElementScroll(
                key: ValueKey('pirc-element-scroll:$scrollId'),
                controller: elementScroll(),
                id: scrollId,
                revision: layoutRevision(),
                overflowX: computed(x, y),
                overflowY: computed(y, x),
                scrollBehavior:
                    layoutComputedStyles()[tree
                            .element
                            .attributes['data-pirc-script-id']]
                        ?.values['scroll-behavior'] ??
                    'auto',
                child: entries.isEmpty
                    ? child
                    : NativeDocumentAbsoluteLayer(
                        flow: child,
                        positioned: entries,
                        useScrollportBasis: true,
                      ),
              );
            }),
      ),
    );
    final relativePosition = NativeDocumentRelativePositionSpec.parse(
      styles,
      direction: TextDirection.ltr,
      computedLengths:
          layoutComputedStyles()[tree.element.attributes['data-pirc-script-id']]
              ?.lengths ??
          const {},
    );
    if (relativePosition != null) {
      tree.register(
        BuildOp(
          debugLabel: 'native-document-relative-position',
          alwaysRenderBlock: false,
          // Move the border box, inside its normal-flow margin allocation.
          priority: 5000005800000000,
          onRenderBlock: (parsed, placeholder) =>
              placeholder.wrapWith((context, child) {
                final parentDirection = parsed.hasParent
                    ? parsed.parent.inheritanceResolvers
                          .resolve(context)
                          .get<TextDirection>()
                    : null;
                return NativeDocumentRelativePosition(
                  spec: relativePosition,
                  direction: parentDirection ?? Directionality.of(context),
                  child: child,
                );
              }),
        ),
      );
    }
    final nativeButton =
        !markdownStyles && buttons.resolveControl(tree.element) != null;
    final borderBox = nativeButton
        ? tree.getStyle('box-sizing')?.term != 'content-box'
        : _documentUsesBorderBox(tree.element);
    final flexItem = _directDocumentFlexItem(tree.element);
    _geometryOwnSizing[tree.element] = true;
    if (padding != EdgeInsets.zero) {
      tree.register(
        BuildOp(
          debugLabel: 'native-document-percentage-padding',
          alwaysRenderBlock: false,
          priority: 5000003500000000,
          onRenderBlock: (_, placeholder) => placeholder.wrapWith(
            (_, child) => NativeDocumentPercentagePadding(
              fractions: padding,
              child: child,
            ),
          ),
          onRenderInline: inlineReplaced
              ? (parsed) {
                  final bits = parsed.bits.whereType<WidgetBit>().toList();
                  if (bits.length != 1) return;
                  bits.single.child.wrapWith(
                    (_, child) => NativeDocumentPercentagePadding(
                      fractions: padding,
                      child: child,
                    ),
                  );
                }
              : null,
        ),
      );
    }
    double negativeMargin(String side, double fontSize) {
      if (!hasDocumentViewport()) return 0;
      final value = styles['margin-$side']?.trim() ?? '';
      if (!value.startsWith('-')) return 0;
      return -(_flexLength(value.substring(1), fontSize)?.resolve(null) ?? 0);
    }

    final hasNegativeMargin = const [
      'left',
      'right',
    ].any((side) => negativeMargin(side, 16) != 0);
    final ownsFlexMargins = _ownsFixedFlexMargins(tree.element);
    final collapsedTop = hasDocumentViewport()
        ? documentPercentTopMargins()[tree
              .element
              .attributes['data-pirc-document-style']]
        : null;
    if (!absolute &&
        (margin != EdgeInsets.zero ||
            hasNegativeMargin ||
            ownsFlexMargins ||
            (collapsedTop?.contributions.isNotEmpty ?? false))) {
      tree.register(
        BuildOp(
          debugLabel: 'native-document-percentage-margin',
          alwaysRenderBlock: false,
          priority: 5000005900000000,
          onRenderBlock: (parsed, placeholder) =>
              placeholder.wrapWith((context, child) {
                final resolved = parsed.inheritanceResolvers.resolve(context);
                final fontSize = resolved.get<TextStyle>()?.fontSize ?? 16;
                return NativeDocumentPercentageMargin(
                  fractions: margin,
                  collapsedTop: collapsedTop,
                  fixed: ownsFlexMargins
                      ? EdgeInsets.fromLTRB(
                          _fixedMargin(styles, 'left', fontSize),
                          _fixedMargin(styles, 'top', fontSize),
                          _fixedMargin(styles, 'right', fontSize),
                          _fixedMargin(styles, 'bottom', fontSize),
                        )
                      : EdgeInsets.fromLTRB(
                          negativeMargin('left', fontSize),
                          0,
                          negativeMargin('right', fontSize),
                          0,
                        ),
                  child: child,
                );
              }),
        ),
      );
    }
    Widget sizedBox(BuildTree parsed, BuildContext context, Widget child) {
      final resolved = parsed.inheritanceResolvers.resolve(context);
      final fontSize = resolved.get<TextStyle>()?.fontSize ?? 16;
      final item = _flexItem(parsed.element, true, fontSize);
      double buttonEdges(List<String> sides) {
        return sides.fold<double>(0, (sum, side) {
          final defaultPadding = const {'left', 'right'}.contains(side)
              ? '6px'
              : '1px';
          final padding =
              _flexLength(
                styles['padding-$side'] ?? defaultPadding,
                fontSize,
              )?.resolve(null) ??
              0;
          final borderStyle = styles['border-$side-style'] ?? 'solid';
          final border = const {'none', 'hidden'}.contains(borderStyle)
              ? 0.0
              : _flexLength(
                      styles['border-$side-width'] ?? '2px',
                      fontSize,
                    )?.resolve(null) ??
                    0;
          return sum + padding + border;
        });
      }

      NativeFlexLength? length(String property) =>
          _flexLength(authored[property], fontSize);

      return NativeDocumentBox(
        applySizing: !absolute,
        geometryOwner: parsed.element,
        geometryOwnerId: parsed.element.attributes['data-pirc-document-style'],
        tightAllocationIsAuthoritative:
            absolute ||
            flexItem ||
            _flexChildStyles(
                  parsed.element.parent ?? parsed.element,
                )['display'] ==
                'grid',
        lengthsAreContentBox: !borderBox,
        intrinsicWidthIsMinimum: const {
          'img',
          'canvas',
        }.contains(parsed.element.localName),
        percentagePadding: padding,
        fillWidth:
            !inlineReplaced &&
            !flexItem &&
            !const {'img', 'canvas'}.contains(parsed.element.localName),
        width: length('width'),
        height: length('height'),
        minWidth: length('min-width'),
        maxWidth: length('max-width'),
        minHeight: length('min-height'),
        maxHeight: length('max-height'),
        horizontalEdges: nativeButton
            ? buttonEdges(['left', 'right'])
            : item.mainEdges,
        verticalEdges: nativeButton
            ? buttonEdges(['top', 'bottom'])
            : item.crossEdges,
        child: child,
      );
    }

    tree.register(
      BuildOp(
        debugLabel: 'native-document-sizing',
        alwaysRenderBlock: false,
        priority: 5000005500000000,
        onRenderBlock: (parsed, placeholder) => placeholder.wrapWith(
          (context, child) => sizedBox(parsed, context, child),
        ),
        onRenderInline: inlineReplaced
            ? (parsed) {
                final bits = parsed.bits.whereType<WidgetBit>().toList();
                if (bits.length != 1) return;
                bits.single.child.wrapWith(
                  (context, child) => sizedBox(parsed, context, child),
                );
              }
            : null,
      ),
    );
  }

  @override
  void parseStyleDisplay(BuildTree tree, String? display) {
    final blockified =
        (_directDocumentFlexItem(tree.element) ||
            _directDocumentGridItem(tree.element)) &&
        const {'inline', 'inline-block', null}.contains(display) &&
        !const {
          'img',
          'canvas',
          'audio',
          'video',
          'input',
          'select',
          'textarea',
        }.contains(tree.element.localName);
    if (!markdownStyles &&
        (const {'block', 'flex', 'grid', 'flow-root'}.contains(display) ||
            blockified ||
            _absoluteSupported(tree.element))) {
      _documentSizing(tree);
    }
    if (!markdownStyles &&
        display == 'inline-block' &&
        !_absoluteSupported(tree.element) &&
        buttons.resolveControl(tree.element) != null) {
      // Core's sizing proxy does not publish authored intrinsic widths to the
      // button's IntrinsicWidth wrapper. Use the native border-box surface.
      _documentSizing(tree, inlineReplaced: true);
    }
    if (_absoluteSupported(tree.element)) {
      tree.register(
        BuildOp(
          alwaysRenderBlock: true,
          debugLabel: 'native-absolute-blockification',
        ),
      );
      return;
    }
    if (!markdownStyles && const {'flex', 'grid'}.contains(display)) {
      if (display == 'grid') {
        tree.register(
          BuildOp(
            debugLabel: 'native-grid-items',
            onVisitChild: (parent, child) {
              if (child.element.parent != parent.element) return;
              child.register(
                BuildOp(
                  alwaysRenderBlock: true,
                  debugLabel: 'native-grid-item',
                  priority: 5000008000000000,
                ),
              );
            },
          ),
        );
      }
      if (display == 'flex') {
        tree.register(
          BuildOp(
            debugLabel: 'native-flex-items',
            onVisitChild: (parent, child) {
              if (child.element.parent != parent.element) return;
              child.register(
                BuildOp(
                  alwaysRenderBlock: true,
                  debugLabel: 'native-flex-item',
                  priority: 5000008000000000,
                  onRenderBlock: (parsed, placeholder) =>
                      placeholder.wrapWith((context, widget) {
                        final horizontal =
                            !(parent.getStyle('flex-direction')?.term ?? 'row')
                                .startsWith('column');
                        final resolved = parsed.inheritanceResolvers.resolve(
                          context,
                        );
                        return NativeFlexItemMarker(
                          group: parent.element,
                          item: _flexItem(
                            parsed.element,
                            horizontal,
                            resolved.get<TextStyle>()?.fontSize ?? 16,
                          ),
                          child: widget,
                        );
                      }),
                ),
              );
            },
          ),
        );
      }
      tree.register(
        BuildOp(
          alwaysRenderBlock: true,
          debugLabel: 'native-document-$display',
          onRenderedChildren: (original, children) => WidgetPlaceholder(
            debugLabel: 'native-document-layout',
            builder: (context, _) {
              final resolved = original.inheritanceResolvers.resolve(context);
              final childWidgets = children
                  .where((child) => !_absolutePlaceholders.contains(child))
                  .map((child) => WidgetPlaceholder.unwrap(context, child))
                  .where((child) => child != widget0)
                  .toList();
              final gap = _layoutLength(original, 'gap', resolved);
              if (display == 'grid') {
                final template = NativeGridTemplate.parse(
                  original.getStyle('grid-template-columns')?.expression,
                );
                if (template == null) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: childWidgets,
                  );
                }
                final spans = <int>[];
                final stretchRows = <bool>[];
                final stretchColumns = <bool>[];
                for (final element in original.element.children) {
                  final styles = customStylesBuilder(element) ?? {};
                  if (styles['display']?.trim().toLowerCase() == 'none' ||
                      _absoluteSupported(element)) {
                    continue;
                  }
                  final start = styles['grid-column-start'];
                  final end = styles['grid-column-end'];
                  final span = start == '1' && end == '-1'
                      ? -1
                      : start?.startsWith('span ') == true
                      ? int.tryParse(start!.substring(5)) ?? 1
                      : 1;
                  spans.add(span);
                  final font = resolved.get<TextStyle>()?.fontSize ?? 16;
                  stretchRows.add(_flexLength(styles['height'], font) == null);
                  stretchColumns.add(
                    _flexLength(styles['width'], font) == null,
                  );
                }
                return NativeDocumentGrid(
                  template: template,
                  rowTemplate: NativeGridTemplate.parse(
                    original.getStyle('grid-template-rows')?.expression,
                  ),
                  stretchColumns: stretchColumns,
                  textDirection: switch (original.getStyle('direction')?.term) {
                    'rtl' => TextDirection.rtl,
                    'ltr' => TextDirection.ltr,
                    _ => null,
                  },
                  spans: spans,
                  stretchRows: stretchRows,
                  columnGap: _layoutLength(
                    original,
                    'column-gap',
                    resolved,
                    gap,
                  ),
                  rowGap: _layoutLength(original, 'row-gap', resolved, gap),
                  children: [
                    for (final child in childWidgets)
                      NativeDocumentContainingBlock(child: child),
                  ],
                );
              }
              final containerStyles = _flexChildStyles(original.element);
              final containerFont = resolved.get<TextStyle>()?.fontSize ?? 16;
              double containerEdge(String property) =>
                  _flexLength(
                    containerStyles[property],
                    containerFont,
                  )?.resolve(null) ??
                  0;
              final heightEdges =
                  containerEdge('padding-top') +
                  containerEdge('padding-bottom') +
                  (containerStyles['border-top-style'] == 'none'
                      ? 0
                      : containerEdge('border-top-width')) +
                  (containerStyles['border-bottom-style'] == 'none'
                      ? 0
                      : containerEdge('border-bottom-width'));
              final direction =
                  original.getStyle('flex-direction')?.term ?? 'row';
              final horizontal = !direction.startsWith('column');
              final align = original.getStyle('align-items')?.term ?? 'stretch';
              final justify =
                  original.getStyle('justify-content')?.term ?? 'flex-start';
              return NativeDocumentFlex(
                containerHeight: _flexLength(
                  containerStyles['height'],
                  containerFont,
                ),
                containerHeightEdges: heightEdges,
                containerBorderBox: _documentUsesBorderBox(original.element),
                axis: horizontal ? Axis.horizontal : Axis.vertical,
                reverse: direction.endsWith('reverse'),
                wrap: switch (original.getStyle('flex-wrap')?.term) {
                  'wrap' => NativeFlexWrap.wrap,
                  'wrap-reverse' => NativeFlexWrap.wrapReverse,
                  _ => NativeFlexWrap.nowrap,
                },
                mainGap: _layoutLength(
                  original,
                  horizontal ? 'column-gap' : 'row-gap',
                  resolved,
                  gap,
                ),
                crossGap: _layoutLength(
                  original,
                  horizontal ? 'row-gap' : 'column-gap',
                  resolved,
                  gap,
                ),
                align: _flexAlign(align) ?? CrossAxisAlignment.stretch,
                justify: switch (justify) {
                  'center' => MainAxisAlignment.center,
                  'flex-end' || 'end' => MainAxisAlignment.end,
                  'space-between' => MainAxisAlignment.spaceBetween,
                  'space-around' => MainAxisAlignment.spaceAround,
                  'space-evenly' => MainAxisAlignment.spaceEvenly,
                  _ => MainAxisAlignment.start,
                },
                alignContent: switch (original
                    .getStyle('align-content')
                    ?.term) {
                  'center' => NativeFlexContent.center,
                  'flex-start' || 'start' => NativeFlexContent.start,
                  'flex-end' || 'end' => NativeFlexContent.end,
                  'space-between' => NativeFlexContent.spaceBetween,
                  'space-around' => NativeFlexContent.spaceAround,
                  'space-evenly' => NativeFlexContent.spaceEvenly,
                  _ => NativeFlexContent.stretch,
                },
                textDirection: switch (original.getStyle('direction')?.term) {
                  'rtl' => TextDirection.rtl,
                  'ltr' => TextDirection.ltr,
                  _ =>
                    resolved.get<TextDirection>() ?? Directionality.of(context),
                },
                group: original.element,
                children: childWidgets,
              );
            },
          ),
        ),
      );
      return;
    }
    if (!markdownStyles &&
        (display == 'block' || display == 'flow-root' || blockified)) {
      tree.register(
        BuildOp(
          debugLabel: 'native-document-block-display',
          alwaysRenderBlock: true,
        ),
      );
      return;
    }
    super.parseStyleDisplay(tree, display);
  }

  @override
  void parseStyle(BuildTree tree, css.Declaration style) {
    if (style.property.startsWith('margin') &&
        _absoluteSupported(tree.element)) {
      return;
    }
    // Core caches sizing while visiting descendants. Registering its sizing
    // operation then resetting styles later keeps stale percentages/minimums.
    // Native document blocks own sizing from the start, so their populated
    // trees (including image caches) never need copying to remove core sizing.
    final display = tree.getStyle('display')?.term;
    final nativeBlock =
        !markdownStyles &&
        (_absoluteSupported(tree.element) ||
            const {'block', 'flex', 'grid', 'flow-root'}.contains(display) ||
            ((_directDocumentFlexItem(tree.element) ||
                    _directDocumentGridItem(tree.element)) &&
                const {'inline', 'inline-block', null}.contains(display) &&
                !const {
                  'img',
                  'canvas',
                  'audio',
                  'video',
                  'input',
                  'select',
                  'textarea',
                }.contains(tree.element.localName)));
    // Fixed flex-item margins must preserve the parent's allocated box.
    // Core's margin Column loosens that allocation, collapsing empty grow and
    // shrink items. The native margin proxy owns these insets instead.
    if (nativeBlock &&
        style.property.startsWith('margin') &&
        _ownsFixedFlexMargins(tree.element)) {
      return;
    }
    final nativeInlineButton =
        !markdownStyles &&
        display == 'inline-block' &&
        buttons.resolveControl(tree.element) != null;
    if ((nativeBlock ||
            _ownsInlineReplacedSizing(tree) ||
            nativeInlineButton) &&
        const {
          'width',
          'height',
          'min-width',
          'max-width',
          'min-height',
          'max-height',
        }.contains(style.property)) {
      return;
    }
    final ownsControlBox =
        !markdownStyles &&
        (_styledToggle(tree.element) != null ||
            textFields.resolveControl(tree.element) != null ||
            selects.resolveControl(tree.element) != null);
    if (ownsControlBox &&
        (const {
              'box-sizing',
              'width',
              'height',
              'min-width',
              'max-width',
              'min-height',
              'max-height',
            }.contains(style.property) ||
            style.property.startsWith('padding') ||
            style.property.startsWith('border') ||
            style.property.startsWith('background'))) {
      // The native surface consumes these declarations; letting HTML core
      // decorate the same element would duplicate its box and padding.
      return;
    }
    const inherited = {
      'color',
      'font-family',
      'font-size',
      'font-style',
      'font-weight',
      'letter-spacing',
      'word-spacing',
      'line-height',
    };
    if (!markdownStyles &&
        style.term == 'inherit' &&
        inherited.contains(style.property)) {
      tree.inherit<String>((resolved, property) {
        final parent = resolved.parent;
        if (parent == null) return resolved;
        final text = parent.prepareTextStyle();
        if (property == 'line-height') {
          return resolved.copyWith(
            value: NormalLineHeight(text.height ?? kTextHeightNone),
          );
        }
        final inheritedStyle = switch (property) {
          'color' => TextStyle(color: text.color),
          'font-family' => TextStyle(
            fontFamily: text.fontFamily,
            fontFamilyFallback: text.fontFamilyFallback ?? const [],
          ),
          'font-size' => TextStyle(fontSize: text.fontSize),
          'font-style' => TextStyle(
            fontStyle: text.fontStyle ?? FontStyle.normal,
          ),
          'font-weight' => TextStyle(
            fontWeight: text.fontWeight ?? FontWeight.normal,
          ),
          'letter-spacing' => TextStyle(letterSpacing: text.letterSpacing ?? 0),
          'word-spacing' => TextStyle(wordSpacing: text.wordSpacing ?? 0),
          _ => const TextStyle(),
        };
        return resolved.copyWith(style: inheritedStyle);
      }, style.property);
      return;
    }
    super.parseStyle(tree, style);
  }

  List<NativeHtmlBackgroundLayer> _backgroundLayers(BuildTree tree) =>
      nativeHtmlBackgroundLayers(
        tree.styles.map((style) {
          final printer = css.CssPrinter();
          style.expression?.visit(printer);
          return MapEntry(style.property, printer.toString().trim());
        }),
      );

  Gradient? _backgroundGradient(BuildTree tree) {
    Gradient? gradient;
    for (final style in tree.styles) {
      if (style.property != 'background' &&
          style.property != 'background-image') {
        continue;
      }
      gradient = null;
      if (style.values.whereType<css.OperatorComma>().isNotEmpty) continue;
      final functions = style.values.whereType<css.FunctionTerm>().where(
        (term) => const {
          'linear-gradient',
          'radial-gradient',
          'conic-gradient',
          'repeating-linear-gradient',
          'repeating-radial-gradient',
          'repeating-conic-gradient',
        }.contains(term.value.toString().toLowerCase()),
      );
      if (functions.length != 1 ||
          style.values.whereType<css.UriTerm>().isNotEmpty) {
        continue;
      }
      final printer = css.CssPrinter();
      functions.single.visit(printer);
      try {
        gradient = parseNativeHtmlBackgroundGradient(printer.toString().trim());
      } on FormatException {
        // The document style engine records unsupported gradient syntax.
      }
    }
    return gradient;
  }

  String? _backgroundImageSize(BuildTree tree) {
    String? result;
    for (final style in tree.styles) {
      if (style.property == 'background') {
        result = null;
        final values = style.values;
        final slash = values.indexWhere((term) => term is css.OperatorSlash);
        if (slash >= 0) {
          final terms = <String>[];
          for (final term in values.skip(slash + 1)) {
            final printer = css.CssPrinter();
            term.visit(printer);
            final text = printer.toString().trim();
            if (term is css.UnitTerm ||
                const {'auto', 'cover', 'contain', '0'}.contains(text)) {
              terms.add(text);
            } else {
              break;
            }
          }
          if (terms.isNotEmpty) result = terms.join(' ');
        }
      } else if (style.property == 'background-size') {
        final printer = css.CssPrinter();
        style.expression?.visit(printer);
        result = printer.toString().trim();
      }
    }
    return result;
  }

  @override
  Widget? buildDecoration(
    BuildTree tree,
    Widget child, {
    BoxBorder? border,
    BorderRadius? borderRadius,
    Color? color,
    DecorationImage? image,
  }) {
    final base = super.buildDecoration(
      tree,
      child,
      border: border,
      borderRadius: borderRadius,
      color: color,
      image: image,
    );
    final gradient = _backgroundGradient(tree);
    if (base == null) return null;
    final layers = _backgroundLayers(tree);
    final positionedGradient =
        gradient != null &&
        layers.length == 1 &&
        (!const {'auto', 'auto auto'}.contains(layers.single.size) ||
            (RegExp(r'[0-9]').hasMatch(layers.single.position) &&
                !RegExp(
                  r'^0(?:%|px)?(?:\s+0(?:%|px)?)?$',
                ).hasMatch(layers.single.position)));
    if (layers.length > 1 || positionedGradient) {
      final providers = layers
          .map(
            (layer) => layer.url == null ? null : backgroundImages(layer.url!),
          )
          .toList();
      final original = base is Container ? base : null;
      final decoration = original?.decoration;
      return Container(
        decoration: NativeHtmlLayeredBackgroundDecoration(
          decoration is BoxDecoration ? decoration : const BoxDecoration(),
          layers,
          providers,
        ),
        alignment: original?.alignment,
        padding: original?.padding,
        constraints: original?.constraints,
        margin: original?.margin,
        transform: original?.transform,
        transformAlignment: original?.transformAlignment,
        foregroundDecoration: original?.foregroundDecoration,
        clipBehavior: original?.clipBehavior ?? Clip.none,
        child: original == null ? base : original.child,
      );
    }
    if (gradient == null) {
      if (base is Container &&
          base.decoration is BoxDecoration &&
          (base.decoration as BoxDecoration).image?.image
              is NativeDocumentBackgroundImage) {
        return Container(
          decoration: NativeHtmlImageBackgroundDecoration(
            base.decoration as BoxDecoration,
            cssPosition:
                layers.singleOrNull?.position ??
                (base.decoration is NativeHtmlImageBackgroundDecoration
                    ? (base.decoration as NativeHtmlImageBackgroundDecoration)
                          .cssPosition
                    : null),
            cssSize:
                _backgroundImageSize(tree) ??
                (image == null &&
                        base.decoration is NativeHtmlImageBackgroundDecoration
                    ? (base.decoration as NativeHtmlImageBackgroundDecoration)
                          .cssSize
                    : null),
          ),
          alignment: base.alignment,
          padding: base.padding,
          constraints: base.constraints,
          margin: base.margin,
          transform: base.transform,
          transformAlignment: base.transformAlignment,
          foregroundDecoration: base.foregroundDecoration,
          clipBehavior: base.clipBehavior,
          child: base.child,
        );
      }
      return base;
    }
    if (base is Container) {
      final decoration = base.decoration;
      if (decoration is BoxDecoration) {
        return Container(
          decoration: NativeHtmlGradientBoxDecoration(decoration, gradient),
          alignment: base.alignment,
          padding: base.padding,
          constraints: base.constraints,
          margin: base.margin,
          transform: base.transform,
          transformAlignment: base.transformAlignment,
          foregroundDecoration: base.foregroundDecoration,
          clipBehavior: base.clipBehavior,
          child: base.child,
        );
      }
    }
    // Keep the wrapper as a Container so the core factory can merge a later
    // background-color/border into this same box instead of painting the
    // gradient twice through nested decorated widgets.
    return Container(
      decoration: NativeHtmlGradientBoxDecoration(
        const BoxDecoration(),
        gradient,
      ),
      child: base,
    );
  }

  void _registerDocumentOpacity(BuildTree tree) {
    if (markdownStyles) return;
    dom.Element? current = tree.element;
    String raw = '1';
    while (current != null) {
      raw = (_flexChildStyles(current)['opacity'] ?? '1').trim().toLowerCase();
      if (raw != 'inherit') break;
      current = current.parent;
    }
    if (const {'initial', 'unset', 'inherit'}.contains(raw)) raw = '1';
    final percent = raw.endsWith('%');
    final number = double.tryParse(
      percent ? raw.substring(0, raw.length - 1) : raw,
    );
    if (number == null || !number.isFinite) return;
    final opacity = (number / (percent ? 100 : 1)).clamp(0.0, 1.0);
    if (opacity == 1) return;
    var blockWrapped = false;
    Widget wrapped(Widget child) => Opacity(opacity: opacity, child: child);
    tree.register(
      BuildOp(
        debugLabel: 'native-document-opacity',
        alwaysRenderBlock: false,
        // Compose the complete border/positioned/transform subtree as one group.
        priority: 5000005780000000,
        onRenderBlock: (parsed, placeholder) {
          blockWrapped = true;
          return placeholder.wrapWith((context, child) => wrapped(child));
        },
        onRenderInline: (parsed) {
          if (blockWrapped ||
              !const {
                'img',
                'canvas',
                'svg',
                'input',
                'button',
                'select',
                'textarea',
                'video',
                'audio',
              }.contains(parsed.element.localName)) {
            return;
          }
          final bits = parsed.bits.whereType<WidgetBit>().toList();
          if (bits.length == 1) {
            bits.single.child.wrapWith((context, child) => wrapped(child));
          }
        },
      ),
    );
  }

  void _registerDocumentTransform(BuildTree tree) {
    if (markdownStyles) return;
    final css = _flexChildStyles(tree.element);
    final spec = NativeDocumentTransformSpec.parse(
      css['transform'],
      origin: css['transform-origin'],
    );
    if (spec == null) return;
    var blockWrapped = false;
    Widget transformed(BuildTree parsed, BuildContext context, Widget child) =>
        NativeDocumentTransform(
          spec: spec,
          viewport: imageViewport(),
          fontSize:
              parsed.inheritanceResolvers
                  .resolve(context)
                  .get<TextStyle>()
                  ?.fontSize ??
              16,
          boxGeometry: (marker) =>
              nativeDocumentPositioningSurface(marker, owner: parsed.element),
          child: child,
        );
    tree.register(
      BuildOp(
        debugLabel: 'native-document-transform',
        alwaysRenderBlock: false,
        // Transform the border box and its measurement, inside flow margins.
        priority: 5000005760000000,
        onRenderBlock: (parsed, placeholder) {
          blockWrapped = true;
          return placeholder.wrapWith(
            (context, child) => transformed(parsed, context, child),
          );
        },
        onRenderInline: (parsed) {
          if (blockWrapped) return;
          if (!const {
            'img',
            'canvas',
            'svg',
            'input',
            'button',
            'select',
            'textarea',
            'video',
            'audio',
          }.contains(parsed.element.localName)) {
            return;
          }
          final bits = parsed.bits.whereType<WidgetBit>().toList();
          if (bits.length != 1) return;
          bits.single.child.wrapWith(
            (context, child) => transformed(parsed, context, child),
          );
        },
      ),
    );
  }

  void _registerLayoutGeometry(BuildTree tree) {
    if (layoutController() == null ||
        !tree.element.attributes.containsKey('data-pirc-script-id')) {
      return;
    }
    // These controls replace the parsed inline/block placeholder. Measure
    // their actual native border box in that replacement builder instead.
    if (!markdownStyles &&
        (textFields.resolveControl(tree.element) != null ||
            selects.resolveControl(tree.element) != null ||
            dates.resolveControl(tree.element) != null ||
            files.resolveControl(tree.element) != null)) {
      return;
    }
    tree.register(
      BuildOp(
        debugLabel: 'native-document-layout-measurement',
        alwaysRenderBlock: false,
        // Outside the border box, inside outer CSS margins. This must not
        // blockify textual inline spans or change their wrapping/baseline.
        priority: 5000005750000000,
        onRenderBlock: (parsed, placeholder) {
          _geometryBlockWrapped[parsed.element] = true;
          return placeholder.wrapWith(
            (_, child) => _measureLayoutElement(parsed.element, child),
          );
        },
        onRenderInline: (parsed) {
          if (_geometryBlockWrapped[parsed.element] == true ||
              !const {
                'img',
                'canvas',
                'input',
                'textarea',
                'select',
                'button',
                'audio',
                'video',
                'svg',
              }.contains(parsed.element.localName)) {
            return;
          }
          final bits = parsed.bits.whereType<WidgetBit>().toList();
          // A single atomic inline box retains its actual RenderBox. Ordinary
          // text fragments and separate inline edge spacers need paragraph range
          // mapping and are left explicitly unmeasured, never made atomic here.
          if (bits.length != 1) return;
          bits.single.child.wrapWith(
            (_, child) => _measureLayoutElement(parsed.element, child),
          );
        },
      ),
    );
  }

  @override
  void parse(BuildTree tree) {
    _registerPointerEvents(tree);
    _registerDocumentTransform(tree);
    _registerDocumentOpacity(tree);
    _registerAbsolutePositioning(tree);
    final absolute = _absoluteSupported(tree.element);
    if (absolute) {
      final replacement = _customWidgetForElement(tree.element);
      if (replacement != null) {
        tree.register(
          BuildOp(
            debugLabel: 'native-absolute-replacement',
            alwaysRenderBlock: true,
            priority: 0,
            onRenderedChildren: (_, children) => WidgetPlaceholder(
              child: replacement is InlineCustomWidget
                  ? replacement.child
                  : replacement,
            ),
          ),
        );
      }
    }
    final rawReplacedElement =
        !markdownStyles &&
        !absolute &&
        const {'img', 'canvas'}.contains(tree.element.localName);
    if (rawReplacedElement) {
      tree.register(
        BuildOp(
          debugLabel: 'native-document-atomic-replaced-box',
          alwaysRenderBlock: false,
          // Use the same atomic build path as core's bordered inline boxes.
          // Replaced elements own one padding/border/margin box, even when
          // padding or margins alone would otherwise become sibling spacers.
          priority: 5000002500000000,
          onParsed: (parsed) {
            if (parsed.isInline != true) return parsed;
            final built = WidgetPlaceholder(
              child: parsed.build(),
              builder: (_, child) {
                final baseline = NativeHtmlReplacedBaseline(child: child);
                return _canRelaxInlineReplacedWidth(parsed)
                    ? NativeHtmlInlineIntrinsicOverflow(
                        intrinsicSize: Size.zero,
                        useChildIntrinsicSize: true,
                        child: baseline,
                      )
                    : baseline;
              },
            );
            return parsed.parent.sub()
              ..append(WidgetBit.inline(parsed, built))
              // Retain a real line box for a sole inline replacement. The
              // core shortcut would otherwise flatten it to a block widget.
              ..append(WidgetBit.inline(parsed, const SizedBox.shrink()));
          },
        ),
      );
      if (_ownsInlineReplacedSizing(tree)) {
        _documentSizing(tree, inlineReplaced: true);
      }
      tree.register(
        BuildOp(
          debugLabel: 'native-document-replaced-bottom-baseline',
          alwaysRenderBlock: false,
          priority: 5000005700000000,
          onRenderInline: (parsed) {
            final bits = parsed.bits.whereType<WidgetBit>().toList();
            if (bits.length != 1) return;
            // A replaced element's baseline is its bottom edge, including when
            // its decoded image/error widget contains text with a top baseline.
            bits.single.child.wrapWith(
              (_, child) => NativeHtmlReplacedBaseline(child: child),
            );
          },
        ),
      );
      tree.register(
        BuildOp(
          debugLabel: 'native-document-replaced-intrinsic-overflow',
          alwaysRenderBlock: false,
          // Atomic inline baselines include the outer margin box. Measure
          // geometry inside margins, but expose overflow outside that box.
          priority: 5000006100000000,
          onRenderInline: (parsed) {
            // Style defaults and the winning cascade are now fully parsed.
            if (!_canRelaxInlineReplacedWidth(parsed)) return;
            final bits = parsed.bits.whereType<WidgetBit>().toList();
            if (bits.length != 1) return;
            bits.single.child.wrapWith(
              (_, child) => NativeHtmlInlineIntrinsicOverflow(
                intrinsicSize: Size.zero,
                useChildIntrinsicSize: true,
                child: child,
              ),
            );
          },
        ),
      );
    }
    _registerLayoutGeometry(tree);
    if (tree.element.localName == 'canvas') {
      final element = tree.element;
      final snapshot = canvases()[element.attributes['data-pirc-script-id']];
      int dimension(String attribute, int fallback) {
        final value = int.tryParse(element.attributes[attribute] ?? '');
        return value == null || value < 0 ? fallback : value;
      }

      final width = snapshot?.width ?? dimension('width', 300);
      final height = snapshot?.height ?? dimension('height', 150);
      final Widget canvas;
      if (width > NativeCanvasLimits.maxDimension ||
          height > NativeCanvasLimits.maxDimension ||
          width * height > NativeCanvasLimits.maxPixels) {
        canvas = Text(tr("畫布尺寸超過目前原生渲染上限。"));
      } else {
        canvas = canvasPointerSurface(
          element,
          Builder(
            builder: (context) {
              final cssWidthSpecified =
                  tree.getStyle('width') != null &&
                  tree.getStyle('width')!.term != 'auto';
              final cssHeightSpecified =
                  tree.getStyle('height') != null &&
                  tree.getStyle('height')!.term != 'auto';
              final runtime = documentRuntime();
              if (runtime == null) {
                return NativeBlankCanvas(
                  width: width.toDouble(),
                  height: height.toDouble(),
                  cssWidthSpecified: cssWidthSpecified,
                  cssHeightSpecified: cssHeightSpecified,
                );
              }
              return runtime.buildCanvas(
                snapshot: snapshot,
                width: width.toDouble(),
                height: height.toDouble(),
                cssWidthSpecified: cssWidthSpecified,
                cssHeightSpecified: cssHeightSpecified,
                images: canvasImages(),
              );
            },
          ),
          tree.getStyle('touch-action')?.term == 'none',
        );
      }
      element.nodes.clear();
      tree.register(
        BuildOp(
          debugLabel: 'native-document-canvas',
          alwaysRenderBlock: false,
          defaultStyles: (_) => {
            'width': 'auto',
            'height': 'auto',
            'min-width': '0px',
            'min-height': '0px',
          },
          onRenderBlock: (_, _) => canvas,
          onRenderInline: (parsed) =>
              parsed.append(WidgetBit.inline(parsed, canvas)),
        ),
      );
    }
    if (tree.element.localName == 'img') {
      NativeResponsiveImageSelection select(bool avif) =>
          selectNativeResponsiveImage(
            tree.element,
            viewportWidth: imageViewport().width,
            viewportHeight: imageViewport().height,
            devicePixelRatio: imageDpr(),
            avifSupported: avif,
            dark: imageDark(),
          );
      var choice = select(NativeRasterImages.avifSupported);
      // Only in-memory (`data:`) AVIF passes through `normalizeAvif`; a
      // remote one would reach the platform decoder, which gets alpha
      // wrong. Take the source chosen without AVIF instead, as before.
      if (NativeRasterImages.avifSupported &&
          !choice.url.trimLeft().toLowerCase().startsWith('data:')) {
        final plain = select(false);
        if (plain.url.isNotEmpty && plain.url != choice.url) choice = plain;
      }
      if (choice.url.isNotEmpty) {
        tree.element.attributes['src'] = choice.url;
        _imageDensities[tree.element] = choice.density;
      }
    }
    tree.register(
      BuildOp(
        alwaysRenderBlock: false,
        debugLabel: 'native-html-gradient-background',
        // flutter_widget_from_html_core 0.17.4 background box-model phase.
        priority: 5000005000000000,
        onRenderBlock: (tree, placeholder) {
          if (_backgroundGradient(tree) == null &&
              _backgroundLayers(tree).length <= 1) {
            return placeholder;
          }
          return placeholder.wrapWith(
            (context, child) => buildDecoration(tree, child),
          );
        },
      ),
    );
    // If an inline HTML element contains only one native math widget, the
    // HTML core can unwrap its WidgetSpan without constructing RichText. In
    // that case buildText cannot apply the element's resolved CSS to the
    // marker. Rebuild just this single math placeholder when the parent
    // BuildTree resolves its inherited style; controls and mixed runs keep
    // their existing render paths.
    tree.register(
      BuildOp(
        debugLabel: 'native-html-standalone-math-style',
        onParsed: (parsed) {
          // A parent with one native math placeholder is flattened directly
          // to the widget, bypassing buildText and its math-span adapter.
          // Resolve the parent's CSS at placeholder build time and rebuild
          // only that math marker. Other inline widgets and mixed runs keep
          // their existing paths.
          final bits = parsed.bits
              .whereType<WidgetBit>()
              .where((bit) => bit.isInline == true)
              .toList(growable: false);
          if (parsed.bits.length != 1 || bits.length != 1) return parsed;
          final bit = bits.single;
          final sourceId = _nativeSourceIdsFor([bit])[bit];
          final native = sourceId == null ? null : sourceSlots[sourceId];
          if (native?.tag != 'pirc-math') return parsed;
          final builder = mathBuilders[native!.tag];
          if (builder == null) return parsed;

          bit.child.wrapWith((context, child) {
            if (child is! InlineCustomWidget) return child;
            final resolved = parsed.inheritanceResolvers.resolve(context);
            final bodyStyle = resolved.prepareTextStyle();
            final built = builder.visitElementAfterWithContext(
              context,
              native,
              bodyStyle,
              bodyStyle,
            );
            if (built is! NativeMarkdownMath) return child;
            final styled = NativeMathParagraph.styleStandaloneMarker(
              built,
              bodyStyle,
            );
            return InlineCustomWidget(
              alignment: child.alignment,
              baseline: child.baseline,
              child: styled,
            );
          });
          return parsed;
        },
      ),
    );
    final styledToggle = _styledToggle(tree.element);
    final styledTextField = textFields.resolveControl(tree.element);
    final select = selects.resolveControl(tree.element);
    final date = dates.resolveControl(tree.element);
    final file = files.resolveControl(tree.element);
    if (!markdownStyles &&
        (styledToggle != null ||
            styledTextField != null ||
            select != null ||
            date != null ||
            file != null)) {
      final nativeControlTree = tree;
      final multiline =
          styledTextField?.kind == NativeHtmlTextFieldKind.textarea;
      tree.element.nodes.clear();
      tree.register(
        BuildOp(
          debugLabel: 'native-document-control-defaults',
          defaultStyles: (_) => {
            'display': 'inline-block',
            if (styledToggle != null)
              'margin': styledToggle.type == NativeHtmlControlType.checkbox
                  ? '3px 3px 3px 4px'
                  : '3px 3px 0px 5px',
            'font-family': multiline || date != null
                ? 'monospace'
                : 'sans-serif',
            'font-size': '13.333333333333334px',
            'font-weight': 'normal',
            'font-style': 'normal',
            'line-height': 'normal',
            'color': dark ? '#ffffff' : '#000000',
          },
          onParsed: (parsed) {
            if (parsed.isEmpty) {
              parsed.append(WidgetBit.block(parsed, const SizedBox.shrink()));
            }
            return parsed;
          },
        ),
      );
      tree.register(
        BuildOp.inline(
          debugLabel: 'native-document-styled-control',
          alignment: multiline
              ? PlaceholderAlignment.aboveBaseline
              : select != null && (select.multiple || select.size > 1)
              ? PlaceholderAlignment.bottom
              : PlaceholderAlignment.baseline,
          onRenderInlineBlock: (controlTree, _) => Builder(
            builder: (context) {
              if (nativeControlTree.getStyle('display')?.term == 'none') {
                return const SizedBox.shrink();
              }
              final preparedStyle = nativeControlTree.inheritanceResolvers
                  .resolve(context)
                  .prepareTextStyle();
              final style = preparedStyle.copyWith(
                textBaseline: TextBaseline.alphabetic,
                fontFamilyFallback:
                    preparedStyle.fontFamilyFallback?.isNotEmpty == true
                    ? preparedStyle.fontFamilyFallback
                    : sourceFontFallback,
              );
              final boxStyle = NativeHtmlControlBoxStyle.fromDeclarations(
                nativeControlTree.styles,
                fontSize: style.fontSize ?? 13.333333333333334,
                dark: dark,
                multiline: multiline,
                uaPreset: file != null || styledToggle != null
                    ? NativeHtmlControlBoxUaPreset.none
                    : date != null
                    ? NativeHtmlControlBoxUaPreset.dateInput
                    : select == null
                    ? null
                    : NativeHtmlControlBoxUaPreset.select,
                currentColor: style.color,
              );
              final control = styledToggle != null
                  ? NativeHtmlControlWidget(
                      key: controls.widgetKeyFor(styledToggle.key),
                      state: controls,
                      control: styledToggle,
                      accent: Theme.of(
                        context,
                      ).extension<RenderColors>()!['accent.default'],
                      boxStyle: boxStyle,
                    )
                  : styledTextField != null
                  ? NativeHtmlTextFieldWidget(
                      state: textFields,
                      field: styledTextField,
                      textStyle: style,
                      boxStyle: boxStyle,
                    )
                  : date != null
                  ? NativeHtmlDateInput(
                      key: dates.widgetKeyFor(date.key),
                      state: dates,
                      control: date,
                      textStyle: style,
                      boxStyle: boxStyle,
                    )
                  : file != null
                  ? NativeHtmlFileInputWidget(
                      key: files.widgetKeyFor(file.key),
                      strings: NativeHtmlFileInputStrings.forLocale(
                        WidgetsBinding.instance.platformDispatcher.locale,
                      ),
                      state: files,
                      control: file,
                      textStyle: style,
                      boxStyle: boxStyle,
                    )
                  : NativeHtmlSelectWidget(
                      key: selects.widgetKeyFor(select!.key),
                      state: selects,
                      control: select,
                      textStyle: style,
                      boxStyle: boxStyle,
                    );
              final anchor = forms.anchorFor(nativeControlTree.element);
              final measuredControl = _measureLayoutElement(
                nativeControlTree.element,
                control,
                controlSurface: true,
              );
              final anchoredControl = anchor == null
                  ? measuredControl
                  : KeyedSubtree(key: anchor, child: measuredControl);
              return Align(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: 1,
                heightFactor: 1,
                child: MediaQuery.withNoTextScaling(
                  child: file == null
                      ? anchoredControl
                      : NativeHtmlInlineOverflowHost(child: anchoredControl),
                ),
              );
            },
          ),
        ),
      );
    }
    if (const {
      'div',
      'p',
      'section',
      'article',
      'form',
      'header',
      'footer',
      'aside',
      'main',
    }.contains(tree.element.localName)) {
      tree.register(
        BuildOp(
          debugLabel: 'native-empty-sized-block',
          onParsed: (parsed) {
            if (parsed.isEmpty &&
                parsed.isInline != true &&
                (parsed.getStyle('height') != null ||
                    parsed.getStyle('min-height') != null)) {
              parsed.append(WidgetBit.block(parsed, const SizedBox.shrink()));
            }
            return parsed;
          },
        ),
      );
    }
    if (registerNativeHtmlDetails(
      tree,
      this,
      detailsGroups,
      onActivate: onScriptTap == null
          ? null
          : (element) => onScriptTap!(element, null),
      summaryFocusNode: scriptFocusableNode,
      onStaticActivate: onDetailsActivate == null
          ? null
          : (element) =>
                onDetailsActivate!(element.attributes['data-pirc-script-id']!),
    )) {
      return;
    }
    if (registerNativeHtmlFieldset(tree, this)) return;
    if (markdownStyles && tree.element.classes.contains('code-head')) {
      tree.register(
        BuildOp(
          debugLabel: 'native-code-header-row',
          alwaysRenderBlock: true,
          onVisitChild: (header, child) {
            if (child.element.parent == header.element) {
              child.register(BuildOp(alwaysRenderBlock: true, priority: 2));
            }
          },
          onRenderedChildren: (header, children) {
            return WidgetPlaceholder(
              child: NativeHtmlCodeHeader(children: children.toList()),
            );
          },
        ),
      );
    }
    if (markdownStyles &&
        tree.element.classes.contains('code-block') &&
        !tree.element.attributes.containsKey('style')) {
      tree.register(
        BuildOp(
          debugLabel: 'native-code-block-inset-line',
          onRenderedBlock: (tree, block) {
            (block as WidgetPlaceholder).wrapWith(
              (context, child) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).extension<RenderColors>()!['web.line'],
                    ),
                  ),
                  child: child,
                ),
              ),
            );
          },
        ),
      );
    }
    final parentButton = _buttonContents[tree.element];
    if (parentButton != null) {
      tree.register(
        BuildOp.inline(
          debugLabel: 'native-button-copy-content',
          onRenderInlineBlock: (tree, child) => NativeHtmlButtonContent(
            state: buttons,
            button: parentButton,
            tree: tree,
            child: child,
          ),
        ),
      );
    }
    final button = buttons.resolveControl(tree.element);
    if (button != null) {
      if (button.input) {
        tree.inherit<NormalLineHeight>(
          (resolved, value) => resolved.copyWith(value: value),
          const NormalLineHeight(kTextHeightNone),
        );
      }
      if (button.copy && !button.input) {
        final inner = dom.Element.tag('span');
        _buttonContents[inner] = button;
        inner.nodes.addAll(tree.element.nodes.toList());
        tree.element.nodes
          ..clear()
          ..add(inner);
      }
      tree.register(
        BuildOp(
          debugLabel: 'native-button-defaults',
          defaultStyles: (_) => {
            'display': 'inline-block',
            'box-sizing': 'border-box',
            'padding': '1px 6px',
            // UA appearance reserves two pixels but paints a one-pixel edge.
            'border': button.nativeAppearance
                ? '2px solid transparent'
                : dark
                ? '2px solid rgb(255, 255, 255)'
                : '2px solid rgb(0, 0, 0)',
            if (button.nativeAppearance) 'border-radius': '2px',
            'background-color': dark
                ? 'rgb(107, 107, 107)'
                : 'rgb(239, 239, 239)',
            if (button.input || !markdownStyles)
              'font-size': markdownStyles ? '16px' : '13.333333333333334px',
            if (!markdownStyles) 'font-family': 'sans-serif',
            if (!markdownStyles) 'color': dark ? '#ffffff' : '#000000',
            if (button.input) 'line-height': 'normal',
            'text-align': 'center',
          },
          onParsed: (tree) {
            if (button.input) {
              tree.addText(
                tree.element.attributes['value'] ??
                    buttons.defaultCaption(button.type),
              );
            }
            return tree;
          },
        ),
      );
      if (_absoluteSupported(tree.element)) {
        tree.register(
          BuildOp(
            debugLabel: 'native-positioned-button',
            alwaysRenderBlock: false,
            priority: 5000005745000000,
            onRenderBlock: (parsed, placeholder) => placeholder.wrapWith(
              (context, child) => NativeHtmlButtonWidget(
                key: buttons.widgetKeyFor(button.key),
                state: buttons,
                button: button,
                tree: parsed,
                child: child,
              ),
            ),
          ),
        );
      } else if (markdownStyles &&
          tree.element.parent?.classes.contains('code-head') == true) {
        tree.register(
          BuildOp(
            debugLabel: 'native-html-button-block',
            onRenderedBlock: (tree, block) {
              (block as WidgetPlaceholder).wrapWith(
                (context, child) => NativeHtmlButtonWidget(
                  key: buttons.widgetKeyFor(button.key),
                  state: buttons,
                  button: button,
                  tree: tree,
                  child: child,
                ),
              );
            },
          ),
        );
      } else {
        tree.register(
          BuildOp.inline(
            debugLabel: 'native-html-button',
            onRenderInlineBlock: (tree, child) => Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              heightFactor: 1,
              child: IntrinsicWidth(
                child: NativeHtmlButtonWidget(
                  key: buttons.widgetKeyFor(button.key),
                  state: buttons,
                  button: button,
                  tree: tree,
                  child: child,
                ),
              ),
            ),
          ),
        );
      }
    }
    final alias = tree.element.attributes[nativeFragmentAttribute];
    if (alias == null) {
      super.parse(tree);
    } else {
      final attributes = tree.element.attributes;
      final id = attributes['id'], name = attributes['name'];
      attributes['id'] = alias;
      if (tree.element.localName == 'a') attributes.remove('name');
      try {
        super.parse(tree);
      } finally {
        if (id == null) {
          attributes.remove('id');
        } else {
          attributes['id'] = id;
        }
        if (name != null) attributes['name'] = name;
      }
    }
    // The pinned HTML core inserts a zero-width, font-height anchor for inline
    // IDs/names at Late.anchor. It has no text baseline. Intrinsic button/table
    // measurements reach it through WidgetSpan's Semantics proxy, which cannot
    // propagate a null dry baseline on this Flutter version. Use the same bottom
    // edge as actual inline layout, preserving the anchor's size and scroll key.
    tree.register(
      BuildOp(
        debugLabel: 'native-inline-anchor-baseline',
        priority: 9000001000000001, // HTML core 0.17.4 Late.anchor + 1.
        onRenderInline: (parsed) {
          final prefix = '${parsed.element.localName}--anchor#';
          for (final bit in parsed.bits.whereType<WidgetBit>()) {
            if (bit.child.debugLabel?.startsWith(prefix) == true) {
              bit.child.wrapWith(
                (_, child) => NativeHtmlReplacedBaseline(child: child),
              );
            }
          }
        },
      ),
    );
    _registerScriptFocus(tree);
    _registerScriptTap(tree);
    if (tree.element.localName != 'label') return;
    final checkable = controls.resolveLabel(tree.element) != null;
    final textField = textFields.resolveLabel(tree.element) != null;
    if (!checkable &&
        !textField &&
        selects.resolveLabel(tree.element) == null &&
        buttons.resolveLabel(tree.element) == null &&
        ranges.resolveLabel(tree.element) == null &&
        dates.resolveLabel(tree.element) == null &&
        files.resolveLabel(tree.element) == null) {
      return;
    }
    tree.register(
      BuildOp(
        alwaysRenderBlock: false,
        debugLabel: 'native-label-control',
        onParsed: (tree) {
          final recognizer = buildGestureRecognizer(
            tree,
            onTap: () {
              if (checkable) {
                controls.activateLabel(tree.element);
              } else if (textField) {
                textFields.activateLabel(tree.element);
              } else if (selects.resolveLabel(tree.element) != null) {
                selects.activateLabel(tree.element);
              } else if (ranges.resolveLabel(tree.element) != null) {
                ranges.activateLabel(tree.element);
              } else if (dates.resolveLabel(tree.element) != null) {
                dates.activateLabel(tree.element);
              } else if (files.resolveLabel(tree.element) != null) {
                files.activateLabel(tree.element);
              } else {
                buttons.activateLabel(tree.element);
              }
            },
          );
          if (recognizer != null) {
            tree.inherit<GestureRecognizer>(
              (resolved, value) =>
                  resolved.copyWith<GestureRecognizer>(value: value),
              recognizer,
            );
            tree.setNonInherited<GestureRecognizer>(recognizer);
          }
          return tree;
        },
        onRenderBlock: (tree, placeholder) {
          final recognizer = tree.getNonInherited<GestureRecognizer>();
          if (recognizer != null) {
            placeholder.wrapWith(
              (context, child) => buildGestureDetector(tree, child, recognizer),
            );
          }
          return placeholder;
        },
      ),
    );
  }

  // URLs are resolved by the app: workspace links and gateway-relative image
  // URLs must not be dropped or rewritten against an invented browser base.
  @override
  String? urlFull(String url) =>
      url.isEmpty ? null : Uri.tryParse(url)?.toString();
  @override
  Widget buildBodyWidget(BuildContext context, Widget child) {
    final entries = _absoluteEntries(context, null);
    return entries.isEmpty
        ? child
        : NativeDocumentAbsoluteLayer(
            flow: child,
            positioned: entries,
            initialContainingBlock: imageViewport(),
          );
  }

  @override
  Widget buildColumnWidget(
    BuildContext context,
    List<Widget> children, {
    CrossAxisAlignment? crossAxisAlignment,
    TextDirection? dir,
  }) {
    final column = super.buildColumnWidget(
      context,
      children,
      crossAxisAlignment: crossAxisAlignment,
      dir: dir,
    );
    if (!hasDocumentViewport()) return column;
    // Normal CSS block flow can extend below an explicitly sized container.
    // Its NativeDocumentBox still owns the definite percentage-height basis;
    // only the flow content is laid out at its natural vertical extent.
    return OverflowBox(
      alignment: Alignment.topLeft,
      fit: OverflowBoxFit.deferToChild,
      minHeight: 0,
      maxHeight: double.infinity,
      child: column,
    );
  }

  @override
  WidgetPlaceholder? buildColumnPlaceholder(
    BuildTree tree,
    Iterable<WidgetPlaceholder> children,
  ) {
    children = children
        .where((child) => !_absolutePlaceholders.contains(child))
        .toList();
    if (!markdownStyles && tree.isInline != true && children.length == 1) {
      if (_directDocumentFlexItem(tree.element)) {
        // A flex parent owns the allocated border box. Keep the block boundary
        // without Align, which would loosen that allocation before the box.
        return WidgetPlaceholder(
          debugLabel: 'native-flex-single-child-boundary',
          child: children.single,
          builder: (_, child) => SizedBox(child: child),
        );
      }
      // Retain this block boundary: the core shortcut reuses the descendant
      // placeholder and applies the canvas min-height to its decoration.
      return WidgetPlaceholder(
        debugLabel: 'native-document-single-child-block',
        child: children.single,
        builder: (context, child) {
          final resolved = tree.inheritanceResolvers.resolve(context);
          final direction = resolved.get<TextDirection>() ?? TextDirection.ltr;
          final textAlign = resolved.get<TextAlign>() ?? TextAlign.start;
          final x = switch (textAlign) {
            TextAlign.center => 0.0,
            TextAlign.left => -1.0,
            TextAlign.right => 1.0,
            TextAlign.end => direction == TextDirection.ltr ? 1.0 : -1.0,
            _ => direction == TextDirection.ltr ? -1.0 : 1.0,
          };
          return Align(
            alignment: Alignment(x, -1),
            widthFactor: 1,
            heightFactor: 1,
            // Match the multi-child block-flow path: a definite parent
            // height is a percentage basis, not a height limit on its content.
            child: hasDocumentViewport()
                ? OverflowBox(
                    alignment: Alignment.topLeft,
                    fit: OverflowBoxFit.deferToChild,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: child,
                  )
                : child,
          );
        },
      );
    }
    return super.buildColumnPlaceholder(tree, children);
  }

  @override
  DecorationImage? buildDecorationImage(
    BuildTree tree,
    String? url, {
    AlignmentGeometry alignment = Alignment.topLeft,
    BoxFit fit = BoxFit.scaleDown,
    ImageRepeat repeat = ImageRepeat.noRepeat,
  }) {
    var effectiveUrl = url;
    var explicitRepeat = false;
    for (final style in tree.styles) {
      if (style.property == 'background' ||
          style.property == 'background-image') {
        final images = style.values.whereType<css.UriTerm>();
        // A newer none/pure-color shorthand resets any older image.
        effectiveUrl = images.isEmpty ? null : images.last.text;
      }
      if (style.property == 'background-repeat') {
        explicitRepeat = true;
      } else if (style.property == 'background') {
        explicitRepeat = style.values.whereType<css.LiteralTerm>().any(
          (term) => const {
            'repeat',
            'no-repeat',
            'repeat-x',
            'repeat-y',
            'space',
            'round',
          }.contains(term.valueAsString),
        );
      }
    }
    if (effectiveUrl == null) return null;
    final provider = backgroundImages(effectiveUrl);
    if (provider == null) return null;
    return DecorationImage(
      image: provider,
      alignment: alignment,
      // CSS auto keeps intrinsic size and clips; it does not scale down.
      fit: fit == BoxFit.scaleDown ? BoxFit.none : fit,
      // CSS initial repeat is repeat; the core package defaults to no-repeat.
      repeat: explicitRepeat ? repeat : ImageRepeat.repeat,
      // CSS image failures retain the foreground and fallback color.
      onError: (_, _) {},
    );
  }

  @override
  ImageProvider? imageProviderFromFileUri(String url) => null;
  @override
  ImageProvider? imageProviderFromAsset(String url) => null;
  @override
  Widget? buildImageWidget(BuildTree tree, ImageSource src) {
    final uri = Uri.tryParse(src.url);
    if (uri == null ||
        !['', 'http', 'https', 'data', 'blob'].contains(uri.scheme)) {
      return Text(src.image?.alt ?? '');
    }
    final density = _imageDensities[tree.element] ?? 1;
    final managed =
        htmlImages()[tree.element.attributes['data-pirc-script-id']];
    final responsive =
        tree.element.attributes.containsKey('srcset') ||
        tree.element.parent?.localName == 'picture';
    final vectorSource = vectorImageSources()[managed?.imageId];
    if (managed != null &&
        (!managed.vector || vectorSource != null) &&
        !managed.animated &&
        managed.status != 'error' &&
        !responsive) {
      Widget image;
      if (managed.status == 'loaded') {
        final decoded = canvasImages()[managed.imageId];
        if (managed.vector && vectorSource != null) {
          final size = svgImageSize(utf8.decode(vectorSource));
          image = size.isEmpty
              ? SizedBox(
                  width: size.width / density,
                  height: size.height / density,
                )
              : NativeImageFrame(
                  naturalSize: size / density,
                  child: SvgPicture.memory(
                    vectorSource,
                    excludeFromSemantics: true,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Text(src.image?.alt ?? ''),
                  ),
                );
        } else {
          image = decoded == null
              ? Text(src.image?.alt ?? '')
              : RawImage(image: decoded, scale: density, fit: BoxFit.contain);
        }
      } else {
        image = const SizedBox.shrink();
      }
      image = Semantics(image: true, label: src.image?.alt, child: image);
      if (src.image?.title?.isNotEmpty == true) {
        image = Tooltip(message: src.image!.title!, child: image);
      }
      return image;
    }
    // Let startup scripts establish image ownership before an independent
    // display fetch can race the script resource request.
    if (deferImageLoading()) return const SizedBox.shrink();
    // Responsive/animated images and SVG sources beyond the document's encoded
    // source budget keep the established provider and vector rendering path.
    if (images != null) {
      return NativeImageDensity(
        density: density,
        crossOrigin: tree.element.attributes.containsKey('crossorigin')
            ? (tree.element.attributes['crossorigin']?.toLowerCase() ==
                      'use-credentials'
                  ? 'use-credentials'
                  : 'anonymous')
            : null,
        loadingLazy:
            tree.element.attributes['loading']?.toLowerCase() == 'lazy',
        child: images!(uri, src.image?.title, src.image?.alt),
      );
    }
    // Standalone renderer: never accept the core package's file:/asset: loaders.
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return NativeRemoteContentGate(
        source: src.url,
        alt: src.image?.alt,
        builder: (_) => Image.network(
          src.url,
          scale: density,
          semanticLabel: src.image?.alt,
          errorBuilder: (_, _, _) => Text(src.image?.alt ?? ''),
        ),
      );
    }
    if (uri.scheme == 'data' &&
        uri.data?.mimeType.startsWith('image/') == true) {
      final bytes = uri.data!.contentAsBytes();
      if (bytes.length <= 32 * 1024 * 1024) {
        return NativeMemoryImage(
          bytes,
          uri.data!.mimeType,
          scale: density,
          semanticLabel: src.image?.alt,
          errorBuilder: (_, _, _) => Text(src.image?.alt ?? ''),
        );
      }
    }
    return Text(src.image?.alt ?? '');
  }

  @override
  Widget? buildText(
    BuildTree tree,
    InheritedProperties resolved,
    InlineSpan text,
  ) {
    if (!markdownStyles) {
      InlineSpan preserveReplacedBoxes(InlineSpan span, double inheritedFont) {
        final font = span.style?.fontSize ?? inheritedFont;
        if (span is WidgetSpan && font == 0) {
          // Flutter scales an entire WidgetSpan to zero at font-size:0. CSS
          // keeps replaced boxes at their own dimensions in a zero-font line.
          // Only the placeholder needs a nonzero scale denominator; surrounding
          // text and the child's own computed typography remain untouched.
          return WidgetSpan(
            alignment: span.alignment,
            baseline: span.baseline,
            style: (span.style ?? const TextStyle()).copyWith(
              fontSize: 1,
              height: 0,
            ),
            child: span.child,
          );
        }
        if (span is! TextSpan || span.children == null) return span;
        final children = span.children!
            .map((child) => preserveReplacedBoxes(child, font))
            .toList();
        if (List.generate(
          children.length,
          (index) => identical(children[index], span.children![index]),
        ).every((same) => same)) {
          return span;
        }
        return TextSpan(
          text: span.text,
          style: span.style,
          children: children,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          semanticsLabel: span.semanticsLabel,
          semanticsIdentifier: span.semanticsIdentifier,
          locale: span.locale,
          spellOut: span.spellOut,
        );
      }

      text = preserveReplacedBoxes(
        text,
        resolved.get<TextStyle>()?.fontSize ?? 16,
      );
    }
    final original = super.buildText(tree, resolved, text);
    final hasFileControl =
        tree.element.localName == 'input' &&
            tree.element.attributes['type']?.toLowerCase() == 'file' ||
        tree.element
            .querySelectorAll('input')
            .any(
              (element) => element.attributes['type']?.toLowerCase() == 'file',
            );
    final hasRawInlineReplacedElement =
        !markdownStyles && _hasRawInlineReplacedElement(tree.element);
    final hasInlineOverflow = hasFileControl || hasRawInlineReplacedElement;
    final clipping =
        [
          tree.getStyle('overflow')?.term,
          tree.getStyle('overflow-x')?.term,
        ].any(
          (value) => const {'hidden', 'clip', 'scroll', 'auto'}.contains(value),
        );
    final inlineBits = tree.bits
        .whereType<WidgetBit>()
        .where((bit) => bit.isInline == true)
        .toList(growable: false);
    final sourceIds = _nativeSourceIdsFor(inlineBits);
    final mathSlots = inlineBits
        .map((bit) {
          final sourceId = sourceIds[bit];
          final native = sourceId == null ? null : sourceSlots[sourceId];
          final builder = native == null ? null : mathBuilders[native.tag];
          final isMath = native?.tag == 'pirc-math' && builder != null;
          return NativeMathInlineSlot(
            expectedWidget: bit.child,
            sourceId: sourceId,
            buildMarker: !isMath
                ? null
                : (
                    context,
                    effectiveStyle, {
                    TextStyle? precedingTextStyle,
                    TextStyle? followingTextStyle,
                  }) {
                    final sourceStyle = bit.parent.inheritanceResolvers
                        .resolve(context)
                        .get<TextStyle>();
                    final rootStyle = tree.inheritanceResolvers
                        .resolve(context)
                        .get<TextStyle>();
                    final adjacentStyles = [
                      precedingTextStyle,
                      followingTextStyle,
                    ].whereType<TextStyle>();
                    final matchingAdjacentStyle = sourceStyle == null
                        ? adjacentStyles.firstOrNull
                        : adjacentStyles
                              .where(
                                (candidate) => _sameInlineMathTextStyle(
                                  sourceStyle,
                                  candidate,
                                ),
                              )
                              .firstOrNull;
                    final canUseAdjacentHeight =
                        sourceStyle?.height != null &&
                        sourceStyle?.height == rootStyle?.height &&
                        matchingAdjacentStyle?.height != null;
                    // The HTML engine may omit an inline CSS line-height from
                    // the detached WidgetSpan's inheritance resolver. Reuse
                    // an adjacent text run only when its other computed style
                    // fields match the source element.
                    final mathStyle = sourceStyle == null
                        ? matchingAdjacentStyle ?? effectiveStyle
                        : canUseAdjacentHeight
                        ? sourceStyle.copyWith(
                            height: matchingAdjacentStyle!.height,
                          )
                        : sourceStyle;
                    final built = builder.visitElementAfterWithContext(
                      context,
                      native!,
                      mathStyle,
                      mathStyle,
                    );
                    return built is NativeMarkdownMath ? built : null;
                  },
            wrapMathWidget: (context, child, inheritedRecognizer) {
              final localRecognizer = bit.parent.inheritanceResolvers
                  .resolve(context)
                  .get<GestureRecognizer>();
              final rootRecognizer = tree.inheritanceResolvers
                  .resolve(context)
                  .get<GestureRecognizer>();
              final recognizer =
                  inheritedRecognizer ??
                  (identical(localRecognizer, rootRecognizer)
                      ? null
                      : localRecognizer);
              final anchor = _htmlAnchorFor(bit.parent.element);
              final href = anchor?.attributes['href'];
              if (anchor != null && href != null && onNavigate != null) {
                final link = NativeHtmlLink(
                  href,
                  target: anchor.attributes['target'] ?? '',
                  download: anchor.attributes['download'],
                  referrerPolicy: anchor.attributes['referrerpolicy'],
                  noopener: nativeHtmlNoopener(anchor.attributes['rel']),
                  noreferrer: (anchor.attributes['rel'] ?? '')
                      .toLowerCase()
                      .split(RegExp(r'\s+'))
                      .contains('noreferrer'),
                  targetSpecified: anchor.attributes.containsKey('target'),
                );
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      final target = _scriptTapEnabled(bit.parent.element)
                          ? bit.parent.element
                          : anchor;
                      if (_scriptTapEnabled(target)) {
                        onScriptTap!(target, () => onNavigate!(link));
                      } else {
                        onNavigate!(link);
                      }
                    },
                    child: child,
                  ),
                );
              }
              return recognizer == null
                  ? child
                  : buildGestureDetector(bit.parent, child, recognizer) ??
                        child;
            },
          );
        })
        .toList(growable: false);

    Widget processRichText(RichText source) {
      final pointerSpans = nativeDocumentHasPointerSpans(source.text);
      // Flutter wraps an oversized first placeholder onto a second line.
      // A paragraph containing only one atomic replaced element has no text
      // wrap opportunity; retain its intrinsic width without an empty line.
      final singleReplaced =
          hasRawInlineReplacedElement &&
          _inlineWidgetElements(tree.element).length == 1 &&
          source.text.toPlainText(includePlaceholders: false).trim().isEmpty;
      final overflow =
          hasInlineOverflow && !clipping && source.overflow == TextOverflow.clip
          ? TextOverflow.visible
          : null;
      if (!mathSlots.any((slot) => slot.buildMarker != null)) {
        // Keep the established no-math path for ordinary HTML and file
        // controls. In particular, do not put unrelated file placeholders
        // inside the TeX paragraph adapter.
        return hasInlineOverflow || pointerSpans
            ? NativeHtmlInlineOverflowRichText.fromRichText(
                source,
                overflow: overflow,
                softWrap: singleReplaced ? false : null,
              )
            : source;
      }
      final adapted = NativeMathParagraph.adaptRichText(
        source,
        slots: mathSlots,
        richTextBuilder: (original, span, registrar) =>
            _NativeHtmlMathRichText.fromRichText(
              original,
              text: span,
              selectionRegistrar: registrar,
              overflow: overflow,
            ),
      );
      if (adapted is NativeMathParagraphContent) return adapted;
      if (adapted is! RichText || (!hasInlineOverflow && !pointerSpans)) {
        return adapted;
      }
      return NativeHtmlInlineOverflowRichText.fromRichText(
        adapted,
        overflow: overflow,
      );
    }

    Widget processRichChild(Widget built) {
      if (built is RichText) return processRichText(built);
      if (built is MouseRegion && built.child is RichText) {
        return MouseRegion(
          key: built.key,
          onEnter: built.onEnter,
          onExit: built.onExit,
          onHover: built.onHover,
          cursor: built.cursor,
          opaque: built.opaque,
          hitTestBehavior: built.hitTestBehavior,
          child: processRichText(built.child! as RichText),
        );
      }
      return built;
    }

    final child = original is Builder
        ? Builder(
            builder: (context) => processRichChild(original.builder(context)),
          )
        : original;
    return child == null
        ? null
        : NativeSelectionGroup(
            breakAfter: tree.element.localName == 'p' ? 2 : 1,
            child: tree.element.localName == 'caption'
                ? Align(alignment: Alignment.center, child: child)
                : child,
          );
  }
}

/// Blocks only the deferred reveal caused by a preventScroll focus operation.
/// Ordinary user scrolling and subsequent editing retain normal viewport flow.
class _NativeHtmlFocusScrollGate extends SingleChildRenderObjectWidget {
  const _NativeHtmlFocusScrollGate({
    required this.suppress,
    required super.child,
  });
  final bool Function() suppress;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeHtmlFocusScrollGate(suppress);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderNativeHtmlFocusScrollGate renderObject,
  ) {
    renderObject.suppress = suppress;
  }
}

class _RenderNativeHtmlFocusScrollGate extends RenderProxyBox {
  _RenderNativeHtmlFocusScrollGate(this.suppress);
  bool Function() suppress;
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (suppress()) return;
    super.showOnScreen(
      descendant: descendant,
      rect: rect,
      duration: duration,
      curve: curve,
    );
  }
}

/// An explicit opener overrides _blank's implicit noopener; noreferrer wins.
bool? nativeHtmlNoopener(String? rel) {
  final tokens = (rel ?? '').toLowerCase().split(RegExp(r'\s+'));
  if (tokens.contains('noreferrer') || tokens.contains('noopener')) return true;
  return tokens.contains('opener') ? false : null;
}

class NativeHtmlLink {
  const NativeHtmlLink(
    this.href, {
    this.target = '',
    this.download,
    this.targetSpecified = false,
    this.referrerPolicy,
    this.noreferrer = false,
    this.noopener,
  });
  final bool? noopener;
  final String? referrerPolicy;
  final bool noreferrer;
  final String href, target;
  final String? download;
  final bool targetSpecified;
}

/// RichText replacement combining breakable TeX and file-control overflow
/// layout. It preserves all public RichText configuration from flutter_html's
/// builder while allowing native TeX render boxes to opt out of unsupported
/// dry-baseline queries.
class _NativeHtmlMathRichText extends RichText {
  _NativeHtmlMathRichText.fromRichText(
    RichText source, {
    required super.text,
    required super.selectionRegistrar,
    TextOverflow? overflow,
  }) : super(
         key: source.key,
         textAlign: source.textAlign,
         textDirection: source.textDirection,
         softWrap: source.softWrap,
         overflow: overflow ?? source.overflow,
         textScaler: source.textScaler,
         maxLines: source.maxLines,
         locale: source.locale,
         strutStyle: source.strutStyle,
         textWidthBasis: source.textWidthBasis,
         textHeightBehavior: source.textHeightBehavior,
         selectionColor: source.selectionColor,
       );

  @override
  RenderNativeHtmlMathParagraph createRenderObject(BuildContext context) {
    assert(textDirection != null || debugCheckHasDirectionality(context));
    return RenderNativeHtmlMathParagraph(
      text,
      textAlign: textAlign,
      textDirection: textDirection ?? Directionality.of(context),
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      locale: locale ?? Localizations.maybeLocaleOf(context),
      strutStyle: strutStyle,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      registrar: selectionRegistrar,
      selectionColor: selectionColor,
    );
  }
}

class RenderNativeHtmlMathParagraph
    extends RenderNativeHtmlInlineOverflowParagraph {
  RenderNativeHtmlMathParagraph(
    super.text, {
    super.textAlign,
    required super.textDirection,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.locale,
    super.strutStyle,
    super.textWidthBasis,
    super.textHeightBehavior,
    super.children,
    super.selectionColor,
    super.registrar,
  });

  @override
  List<PlaceholderDimensions> layoutInlineChildren(
    double maxWidth,
    ChildLayouter layoutChild,
    ChildBaselineGetter getChildBaseline,
  ) {
    final dryBaseline = identical(
      getChildBaseline,
      ChildLayoutHelper.getDryBaseline,
    );
    return super.layoutInlineChildren(maxWidth, layoutChild, (
      child,
      constraints,
      baseline,
    ) {
      if (dryBaseline && _containsNativeInlineMath(child)) return null;
      return getChildBaseline(child, constraints, baseline);
    });
  }
}

bool _containsNativeInlineMath(RenderObject root) {
  if (root is RenderNativeInlineMath) return true;
  var found = false;
  root.visitChildren((child) {
    if (!found) found = _containsNativeInlineMath(child);
  });
  return found;
}

/// Explicit scrolling for native navigation, independently of URL dispatch.
class NativeHtmlViewportController {
  var key = GlobalKey<HtmlWidgetState>();
  void resetContent() {
    key = GlobalKey<HtmlWidgetState>();
  }

  final _fragmentNonce = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  NativeDocumentFragmentIndex indexDocument(dom.Document document) =>
      NativeDocumentFragmentIndex.fromDocument(document, _fragmentNonce);
  Object? _fragmentOwner;
  NativeDocumentFragmentIndex? _fragments;
  Object? _nativeRevealOwner;
  NativeFragmentRevealResult Function(String?, NativeFragmentRevealPhase, bool)?
  _nativeReveal;
  String? lastFragmentDifference;
  void bindNativeReveal(
    Object owner,
    NativeFragmentRevealResult Function(
      String?,
      NativeFragmentRevealPhase,
      bool,
    )?
    reveal,
  ) {
    if (reveal == null && !identical(owner, _nativeRevealOwner)) return;
    _nativeRevealOwner = reveal == null ? null : owner;
    _nativeReveal = reveal;
  }

  Object? _fragmentFocusOwner;
  NativeFragmentFocusResult Function(String?, bool Function())? _fragmentFocus;
  String? Function()? _readFocusedNativeId;
  NativeDocumentFocusCaret? Function()? _readFocusCaret;
  NativeDocumentFocusCaret? get focusCaret => _readFocusCaret?.call();
  String? get focusedNativeElementId => _readFocusedNativeId?.call();
  void _bindFragmentFocus(
    Object owner,
    NativeFragmentFocusResult Function(String?, bool Function()) focus,
    String? Function() read,
    NativeDocumentFocusCaret? Function() caret,
  ) {
    _fragmentFocusOwner = owner;
    _fragmentFocus = focus;
    _readFocusedNativeId = read;
    _readFocusCaret = caret;
  }

  void _unbindFragmentFocus(Object owner) {
    if (!identical(owner, _fragmentFocusOwner)) return;
    _fragmentFocusOwner = null;
    _fragmentFocus = null;
    _readFocusedNativeId = null;
    _readFocusCaret = null;
  }

  void _bindFragments(Object owner, NativeDocumentFragmentIndex fragments) {
    _fragmentOwner = owner;
    _fragments = fragments;
  }

  void _unbindFragments(Object owner) {
    if (identical(owner, _fragmentOwner)) {
      _fragmentOwner = null;
      _fragments = null;
    }
  }

  NativeDocumentFragmentTarget? fragmentTarget(String raw) =>
      _fragments?.select(raw);

  int _completedFragmentReveals = 0;
  @visibleForTesting
  int get completedFragmentReveals => _completedFragmentReveals;

  /// Restore reading position after the destination's native layout settles.
  /// A target style change may otherwise anchor-compensate an earlier jump.
  Future<bool> restoreScrollOffset(
    ScrollController scroll,
    double offset, {
    bool Function()? isCurrent,
  }) async {
    for (var attempt = 0; attempt < 128; attempt++) {
      if (isCurrent?.call() == false) return false;
      final handler = _nativeReveal;
      if (scroll.hasClients &&
          scroll.position.hasContentDimensions &&
          (handler == null ||
              handler(null, NativeFragmentRevealPhase.prepare, false) ==
                  NativeFragmentRevealResult.handled)) {
        scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
        return true;
      }
      WidgetsBinding.instance.ensureVisualUpdate();
      await WidgetsBinding.instance.endOfFrame;
    }
    // Some static documents contain boxes outside anchor measurement support.
    // Retain their known native reading position and expose the missing gate.
    lastFragmentDifference = 'history_layout_not_ready';
    if (isCurrent?.call() != false &&
        scroll.hasClients &&
        scroll.position.hasContentDimensions) {
      scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
    }
    return false;
  }

  Future<bool> scrollToFragment(
    String fragment, {
    bool Function()? isCurrent,
    bool allowUnindexedTop = false,
    NativeDocumentFragmentTarget? retainedTarget,
    bool preserveRootOffset = false,
  }) async {
    lastFragmentDifference = null;
    var focusPrepared = false, centerFocus = false;
    String? selectedId;
    NativeDocumentFragmentTarget? selectedTarget = retainedTarget;
    try {
      for (var attempt = 0; attempt < 128; attempt++) {
        if (isCurrent?.call() == false) return false;
        final target =
            selectedTarget ??
            _fragments?.select(fragment) ??
            (_fragments == null &&
                    allowUnindexedTop &&
                    (fragment.isEmpty ||
                        decodeNativeDocumentFragment(fragment).toLowerCase() ==
                            'top')
                ? const NativeDocumentFragmentTarget.top()
                : null);
        if (_fragments != null && target == null) return false;
        if (target != null) {
          if (!target.top && target.anchor == null && target.nativeId == null) {
            return false;
          }
          final nativeId = focusPrepared
              ? selectedId
              : target.top
              ? null
              : target.nativeId ?? _fragments?.nativeIdFor(target.anchor!);
          final handler = _nativeReveal;
          if (handler == null) {
            lastFragmentDifference = 'unmeasured_target';
            return target.anchor == null ? false : _scrollAlias(target.anchor!);
          }
          if (!target.top && nativeId == null) {
            WidgetsBinding.instance.ensureVisualUpdate();
            await WidgetsBinding.instance.endOfFrame;
            continue;
          }
          if (!focusPrepared) {
            final ready = handler(
              nativeId,
              NativeFragmentRevealPhase.prepare,
              preserveRootOffset,
            );
            if (ready == NativeFragmentRevealResult.unsupported) {
              lastFragmentDifference = 'unsupported_native_geometry';
              return target.anchor == null
                  ? false
                  : _scrollAlias(target.anchor!);
            }
            if (ready == NativeFragmentRevealResult.handled) {
              final focus = target.top
                  ? NativeFragmentFocusResult.unchanged
                  : _fragmentFocus?.call(nativeId, isCurrent ?? () => true) ??
                        NativeFragmentFocusResult.unchanged;
              if (focus != NativeFragmentFocusResult.unavailable) {
                centerFocus = focus == NativeFragmentFocusResult.changed;
                focusPrepared = true;
                selectedId = nativeId;
                selectedTarget = target;
              }
            }
            WidgetsBinding.instance.ensureVisualUpdate();
            await WidgetsBinding.instance.endOfFrame;
            continue;
          }
          if (centerFocus && focusedNativeElementId != nativeId) {
            lastFragmentDifference = 'fragment_focus_redirect';
            centerFocus = false;
          }
          final result = handler(
            nativeId,
            centerFocus
                ? NativeFragmentRevealPhase.centered
                : NativeFragmentRevealPhase.standard,
            preserveRootOffset,
          );
          if (result == NativeFragmentRevealResult.handled) return true;
          if (result == NativeFragmentRevealResult.unsupported) {
            lastFragmentDifference = 'unsupported_native_geometry';
            return target.anchor == null ? false : _scrollAlias(target.anchor!);
          }
        }
        WidgetsBinding.instance.ensureVisualUpdate();
        await WidgetsBinding.instance.endOfFrame;
      }
      lastFragmentDifference = 'layout_not_ready';
      return false;
    } finally {
      _completedFragmentReveals++;
    }
  }

  bool resolvingAnchor = false;
  final _resolvingUrls = <String, int>{};
  bool resolvingAnchorUrl(String url) => _resolvingUrls.containsKey(url);
  Future<bool> _scrollAlias(String alias) async {
    final url = '#$alias';
    _resolvingUrls.update(url, (count) => count + 1, ifAbsent: () => 1);
    resolvingAnchor = true;
    try {
      return await key.currentState?.scrollToAnchor(alias) ?? false;
    } finally {
      final count = _resolvingUrls[url]! - 1;
      if (count == 0) {
        _resolvingUrls.remove(url);
      } else {
        _resolvingUrls[url] = count;
      }
      resolvingAnchor = _resolvingUrls.isNotEmpty;
    }
  }

  Future<bool> scrollToFragmentTarget(NativeDocumentFragmentTarget target) =>
      target.anchor == null
      ? Future.value(false)
      : _scrollAlias(target.anchor!);
  Future<bool> scrollToAnchor(String id) =>
      _scrollAlias(_fragments?.anchorFor(id) ?? id);
}

enum NativeFragmentRevealResult { handled, unavailable, unsupported }

enum NativeFragmentRevealPhase { prepare, standard, centered }

enum NativeFragmentFocusResult { unavailable, unchanged, changed }
