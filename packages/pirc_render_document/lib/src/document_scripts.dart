import 'package:pirc_render/src/render_l10n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/document_html_image.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'document_canvas.dart';
import 'document_integrity.dart';
import 'document_json.dart';
import 'document_origin.dart';
import 'document_resource_limiter.dart';
import 'scripts_platform.dart';
import 'document_script_resources.dart';
import 'document_script_images.dart';
import 'package:pirc_render/src/document_object_urls.dart';
import 'document_style_loading.dart';
import 'document_dynamic_styles.dart';
import 'document_environment.dart';
import 'package:pirc_render/src/html_document_styles.dart';

/// One isolated environment per document, through the `scripts` channel
/// ([ScriptsPlatform]). DOM snapshots and bounded resource messages cross
/// this boundary. The document has an opaque origin: its requests carry no
/// credentials, and its storage and cookies belong to its own session.
class NativeDocumentScripts extends ChangeNotifier with WidgetsBindingObserver {
  static const int _maxClassicScriptsPerTurn = 128;
  static const int _maxClassicScriptBytes = 4 * 1024 * 1024;
  static const int _maxClassicScriptErrorChars = 4096;
  static const int _maxSafeScriptId = 9007199254740991;
  static const Set<String> _oneShotResponseFields = {
    'resourceRequests',
    'resourceCancellations',
    'filePickerActions',
    'formActions',
    'focusActions',
    'scrollActions',
    'navigationActions',
    'cookieWrites',
  };

  NativeDocumentScripts(this.platform, {this.clockMilliseconds}) {
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _appVisible =
        lifecycle == null ||
        lifecycle == AppLifecycleState.resumed ||
        lifecycle == AppLifecycleState.inactive;
  }
  final ScriptsPlatform platform;

  /// The open session; null before [start] and after a close.
  DocumentScriptSession? _session;
  String get _owner => _session?.owner ?? '';
  final _limiter = DocumentResourceLimiter();
  final String _objectUrlNonce = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  static final Set<Future<void>> _pendingClosures = {};
  Future<void> _closed = Future.value();
  Future<void> get closed => _closed;
  bool get occupiesSlot => !_disposed && (_id != null || loading);
  int? _id;
  int _lastClassicScriptId = 0;
  Object? _layoutOwner;
  Future<Json?> Function(int revision, int generation)? _layoutCapture;
  void Function(Json)? _layoutAccepted;
  final _layoutWaits = <Completer<void>>{};
  bool _hostLayoutEnabled = false, _layoutRefreshQueued = false;
  int _layoutGeneration = 0;
  int layoutRevision = 0;
  Set<String> layoutElementIds = const {};

  void bindLayout(
    Object owner,
    Future<Json?> Function(int, int)? capture, {
    void Function(Json)? onAccepted,
  }) {
    if (_disposed || (capture == null && !identical(_layoutOwner, owner))) {
      return;
    }
    _cancelLayoutWaits();
    _layoutOwner = capture == null ? null : owner;
    _layoutCapture = capture;
    _layoutAccepted = capture == null ? null : onAccepted;
    if (capture != null && ready) refreshLayout();
    _schedule();
  }

  /// Only the renderer that still owns the document may detach its activity.
  /// Replacing a view can overlap its successor within the same Flutter frame.
  void detachView(Object owner, {bool preserveFilePicker = false}) {
    if (!identical(_layoutOwner, owner)) return;
    bindLayout(owner, null);
    setActivity(
      attached: false,
      visible: false,
      preserveFilePicker: preserveFilePicker,
    );
  }

  void _cancelLayoutWaits() {
    for (final waiter in _layoutWaits.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _layoutWaits.clear();
  }

  void refreshLayout() {
    if (_disposed ||
        !ready ||
        !_hostLayoutEnabled ||
        _layoutCapture == null ||
        !_attached ||
        !_foreground ||
        _layoutRefreshQueued) {
      return;
    }
    _layoutRefreshQueued = true;
    _pendingEvents++;
    _tail = _tail.then((_) async {
      final oldContent = content;
      final oldCanvases = canvases;
      final oldDiagnostics = diagnostics;
      final oldActions = _formActions;
      final oldNavigation = _navigationActions;
      final oldFilePickerActions = _filePickerActions;
      final oldFocusActions = _focusActions;
      final oldScrollActions = _scrollActions;
      try {
        if (!_disposed &&
            ready &&
            _attached &&
            _foreground &&
            _layoutCapture != null) {
          await _run('__pircDocument.snapshot()', refreshLayoutFirst: true);
        }
      } catch (error) {
        await _failInteraction(error);
      } finally {
        _layoutRefreshQueued = false;
        _pendingEvents--;
        if (!_disposed &&
            _pendingEvents == 0 &&
            // A preceding event may have queued native work while this
            // refresh kept the notification batch open. Flush that work even
            // when the refresh itself did not change its queue identity.
            (_scrollActions.isNotEmpty ||
                _formActions.isNotEmpty ||
                _navigationActions.isNotEmpty ||
                _filePickerActions.isNotEmpty ||
                _focusActions.isNotEmpty ||
                !identical(oldContent, content) ||
                !identical(oldCanvases, canvases) ||
                !listEquals(oldDiagnostics, diagnostics) ||
                !identical(oldActions, _formActions) ||
                !identical(oldNavigation, _navigationActions) ||
                !identical(oldFilePickerActions, _filePickerActions) ||
                !identical(oldFocusActions, _focusActions) ||
                !identical(oldScrollActions, _scrollActions))) {
          notifyListeners();
        }
        _schedule();
      }
    });
  }

  bool _nativeCookies = false;
  bool _disposed = false, _started = false;
  Future<void> _tail = Future.value();
  final _startupFinished = Completer<void>();
  int _pendingEvents = 0;

  /// Includes the frame before start() runs, not just active VM evaluation.
  bool get initialTargetSelectionPending =>
      !_disposed &&
      (!_startupFinished.isCompleted ||
          loading ||
          ready && fragmentTargetReady == false);

  /// Native defaults must wait until prior DOM/history publications have drained.
  bool get hasPendingPublication =>
      loading || _pendingEvents != 0 || _layoutRefreshQueued;
  final List<Json> _resourceQueue = [];
  final List<Json> _resourceCompletions = [];
  final Map<String, int> _lastResourceId = {};
  final _imagePool = NativeDocumentImagePool();
  Map<String, ui.Image> get canvasImages => _imagePool.images;
  Map<String, Uint8List> get vectorImageSources => _imagePool.vectorSources;
  int _activeResources = 0;
  final Set<String> _activeResourceRequests = {};
  final Set<String> _cancelledResourceRequests = {};
  bool _completionScheduled = false;
  NativeDynamicDocumentStyles? _documentStyles;
  String _styleEncoding = 'utf-8';
  bool _hasStylesSnapshot = false;
  Set<String> _currentStyleRequests = {};
  String? documentBaseUrl;
  String? fragmentTargetId;
  bool? fragmentTargetReady;
  bool fragmentAncestorsRevealed = false;
  bool initialRootScrollOverride = false;
  List<NativeDocumentStylesheet>? get stylesheets =>
      _hasStylesSnapshot ? _documentStyles?.stylesheets : null;

  void configureStyles({
    required String encoding,
    List<NativePreparedDocumentStyle> prepared = const [],
  }) {
    if (_started) return;
    _styleEncoding = encoding;
    _documentStyles = NativeDynamicDocumentStyles(seeds: prepared);
  }

  void _acceptStyles(Json snapshot) {
    final value = snapshot['stylesheets'];
    if (value == null) return;
    if (value is! Map) {
      throw FormatException(tr("Invalid stylesheet snapshot."));
    }
    final model = _documentStyles ??= NativeDynamicDocumentStyles();
    final descriptor = obj(value);
    model.update(descriptor);
    _hasStylesSnapshot = true;
    final owners = [
      ...(descriptor['sheets'] as List? ?? const []),
      ...(descriptor['links'] as List? ?? const []),
    ];
    _currentStyleRequests = {
      for (final owner in owners)
        if (owner is Map && owner['transportId'] is String)
          owner['transportId'] as String,
    };
    if (snapshot['documentBaseURL'] is String) {
      documentBaseUrl = snapshot['documentBaseURL'] as String;
    }
  }

  Future<Json> _loadStylesheetResource(int identity, Json request) async {
    final requestId = request['id'] as String;
    bool current() =>
        !_disposed &&
        _id == identity &&
        ready &&
        !_cancelledResourceRequests.contains(requestId) &&
        _currentStyleRequests.contains(requestId);
    if (!current()) throw StateError(tr("Stylesheet document changed."));
    final model = _documentStyles!;
    var loaded = model.takeSeed(requestId);
    if (loaded == null) {
      final options = NativeStylesheetRequestOptions(
        crossOrigin: request['crossOrigin'] as String?,
        integrity: request['integrity'] as String?,
        referrerPolicy: request['referrerPolicy'] as String?,
        // The initiating page URL is host state, never an authored request field.
        // Imported sheets replace this with their verified native response URL.
        referrerUrl: _locationUrl ?? '',
      );
      final loader = NativeDocumentStyleLoader(
        isCurrent: current,
        resolve: (reference, base) async =>
            resolveNativeDocumentUrl(reference, base),
        fetch: (_, _) async =>
            throw StateError(tr("Stylesheet options required.")),
        fetchWithOptions: (reference, base, options) async {
          if (!current()) throw StateError(tr("Stylesheet document changed."));
          final response = await _resource(identity, {
            ...options.arguments(reference),
            'id': requestId,
          });
          if (!current()) throw StateError(tr("Stylesheet document changed."));
          return nativeStylesheetResponse(response);
        },
      );
      loaded = request['ownerType'] == 'style'
          ? await loader.loadInline(
              request['cssText'] as String,
              baseUrl: request['baseURL'] as String,
              documentEncoding: _styleEncoding,
              options: options,
            )
          : await loader.loadExternal(
              request['url'] as String,
              baseUrl: request['baseURL'] as String,
              documentEncoding: _styleEncoding,
              options: options,
            );
    }
    if (!current() || !model.complete(requestId, loaded)) {
      throw StateError(tr("Stylesheet response is stale."));
    }
    return {
      'id': requestId,
      'ok': loaded.loaded,
      if (!loaded.loaded) 'error': loaded.diagnostics.join('\n'),
    };
  }

  NativeDocumentEnvironment _environment = const NativeDocumentEnvironment();
  NativeDocumentEnvironment? _publishedEnvironment;
  bool _environmentQueued = false;
  Future<void> _environmentOperation = Future.value();
  NativeDocumentEnvironment get environment => _environment;

  /// Initial layout configures this before startup. Later changes share the
  /// serialized evaluation queue; retained history only stores the latest value.
  Future<void> updateEnvironment(NativeDocumentEnvironment environment) {
    if (_disposed) return Future.value();
    environment.toJson(); // Reject non-JSON display metrics before queueing.
    _environment = environment;
    return _serviceEnvironment();
  }

  Future<void> _serviceEnvironment() {
    if (_environmentQueued) return _environmentOperation;
    if (_disposed ||
        !ready ||
        _id == null ||
        !_attached ||
        !_foreground ||
        _publishedEnvironment == _environment) {
      return Future.value();
    }
    _environmentQueued = true;
    _pendingEvents++;
    final identity = _id;
    final operation = _tail.then((_) async {
      try {
        while (!_disposed &&
            ready &&
            _attached &&
            _foreground &&
            _id == identity &&
            _publishedEnvironment != _environment) {
          final next = _environment;
          final result = await _run(
            '__pircDocument.updateEnvironment(${jsonEncode({'environment': next.toJson(), 'now': _now})})',
            refreshLayoutFirst: true,
          );
          if (result['layoutDeferred'] == true) break;
          if (!_disposed && ready && _id == identity) {
            _publishedEnvironment = next;
          }
        }
      } catch (error) {
        await _failInteraction(error);
      } finally {
        _environmentQueued = false;
        _pendingEvents--;
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        _schedule();
      }
    });
    _environmentOperation = operation;
    _tail = operation;
    return operation;
  }

  // HTTP work never holds the evaluation queue: a loaded script may enqueue
  // another script or fetch, and user events must remain responsive while waiting.
  void _acceptResources(Iterable<Json> responses) {
    final received = <Json>[];
    final cancelled = <String>{};
    for (final result in responses) {
      final rawCancelled = result['resourceCancellations'] ?? const [];
      if (rawCancelled is! List || rawCancelled.length > 256) {
        throw FormatException(tr("Invalid document cancellation batch."));
      }
      for (final id in rawCancelled) {
        if (id is! String ||
            !RegExp(
              r'^(script|fetch|image|stylesheet)-[1-9][0-9]{0,15}$',
            ).hasMatch(id)) {
          throw FormatException(tr("Invalid document resource cancellation."));
        }
        cancelled.add(id);
      }
      final raw = result['resourceRequests'];
      if (raw == null) continue;
      if (raw is! List || raw.length > 128) {
        throw FormatException(tr("Invalid document resource batch."));
      }
      for (final item in raw) {
        if (item is! Map) {
          throw FormatException(tr("Invalid document resource."));
        }
        final request = obj(item);
        final id = request['id'];
        final match = id is String
            ? RegExp(r'^(script|fetch|image|stylesheet)-(\d+)$').firstMatch(id)
            : null;
        if (match == null || request['kind'] != match.group(1)) {
          throw FormatException(tr("Invalid document resource identity."));
        }
        final kind = match.group(1)!;
        final serial = int.tryParse(match.group(2)!);
        if (serial == null || serial <= 0) {
          throw FormatException(tr("Invalid document resource serial."));
        }
        if (serial <= (_lastResourceId[kind] ?? 0)) continue;
        _lastResourceId[kind] = serial;
        received.add(request);
      }
    }
    // Validate the entire batch before initiating I/O. Queued or completed work
    // can be dropped locally; only genuinely active HTTP needs a native cancel.
    received.removeWhere((request) => cancelled.contains(request['id']));
    _resourceQueue.removeWhere((request) => cancelled.contains(request['id']));
    _resourceCompletions.removeWhere((completion) {
      if (!cancelled.contains(completion['id'])) return false;
      _imagePool.acknowledge(completion['imageId'] as String?);
      return true;
    });
    for (final id in cancelled.intersection(_activeResourceRequests)) {
      if (_cancelledResourceRequests.add(id) && !_limiter.cancel(id)) {
        // It already went out (a request still waiting for a slot never
        // will): Kotlin cancels it, or refuses it if it has not begun yet.
        unawaited(_cancelResource(_id!, id));
      }
    }
    if (_resourceQueue.length +
            _resourceCompletions.length +
            _activeResources +
            received.length >
        256) {
      throw FormatException(
        tr("Too many pending document resources (maximum 256)."),
      );
    }
    _resourceQueue.addAll(received);
    _serviceResources();
  }

  void _serviceResources() {
    if (_disposed || !ready || !_attached || !_foreground) return;
    if (_resourceCompletions.isNotEmpty && !_completionScheduled) {
      _completionScheduled = true;
      _pendingEvents++;
      _tail = _tail.then((_) async {
        Json? completed;
        try {
          // An earlier queued script evaluation can cancel the final response
          // after this callback was scheduled but before it gets its turn.
          if (_disposed ||
              !ready ||
              !_attached ||
              !_foreground ||
              _resourceCompletions.isEmpty) {
            return;
          }
          completed = _resourceCompletions.removeAt(0);
          completed['now'] = _now;
          await _run(
            '__pircDocument.completeResource(${jsonEncode(completed)})',
          );
        } catch (error) {
          await _failInteraction(error);
        } finally {
          _imagePool.acknowledge(completed?['imageId'] as String?);
          _completionScheduled = false;
          _pendingEvents--;
          if (!_disposed && _pendingEvents == 0) notifyListeners();
          _serviceResources();
          _schedule();
        }
      });
    }
    while (_activeResources < 6 && _resourceQueue.isNotEmpty) {
      final request = _resourceQueue.removeAt(0);
      final identity = _id!;
      _activeResources++;
      _activeResourceRequests.add(request['id'] as String);
      unawaited(_loadResource(identity, request));
    }
  }

  Future<void> _loadResource(int identity, Json request) async {
    Json completion;
    try {
      if (request['kind'] == 'stylesheet') {
        completion = await _loadStylesheetResource(identity, request);
      } else if (request['kind'] == 'image') {
        completion = await _loadImageResource(identity, request);
      } else {
        final response = await _resource(identity, request);
        completion = completeDocumentScriptResource(request, response);
      }
    } catch (error) {
      completion = {'id': request['id'], 'ok': false, 'error': _message(error)};
    }
    completion['completedAt'] = _now;
    _activeResources--;
    final requestId = request['id'] as String;
    _activeResourceRequests.remove(requestId);
    final cancelled = _cancelledResourceRequests.remove(requestId);
    if (_disposed || !ready || _id != identity || cancelled) {
      _imagePool.acknowledge(completion['imageId'] as String?);
      _serviceResources();
      return;
    }
    _resourceCompletions.add(completion);
    _serviceResources();
  }

  Future<void> _cancelResource(int identity, String requestId) async {
    try {
      final session = _session;
      if (session == null || session.id != identity) return;
      await platform.cancelResource(session, requestId);
    } catch (error) {
      if (!_disposed && ready && _id == identity) {
        await _failInteraction(error);
        notifyListeners();
      }
    }
  }

  Future<Json> _loadImageResource(int identity, Json request) async {
    final url = request['url'];
    if (url is! String || url.length > 3 * 1024 * 1024) {
      throw FormatException(tr("Invalid image URL."));
    }
    final uri = Uri.tryParse(url);
    Uint8List bytes;
    String mime;
    var originClean = true;
    if (uri?.scheme == 'data') {
      final data = uri!.data;
      if (data == null) throw FormatException(tr("Invalid image data URL."));
      bytes = data.contentAsBytes();
      mime = data.mimeType;
    } else if (uri?.scheme == 'blob') {
      final value = await readObjectURL(url);
      final blob = NativeDocumentBlob.fromBridge(url, value);
      bytes = blob.bytes;
      mime = blob.mimeType;
    } else {
      // Remote images of a document load only after the user taps them; a
      // script cannot fetch one (plans/roadmap.md M8 step 6).
      throw StateError(tr("Remote images load only after a tap."));
    }
    if (_disposed || _id != identity || !ready) {
      throw StateError(tr("Image document changed."));
    }
    return _imagePool.decode(
      request['id'] as String,
      bytes,
      mime,
      originClean: originClean,
    );
  }

  int _formActionSerial = 0;
  List<Json> _navigationActions = const [];
  List<Json> get navigationActions => _navigationActions;
  int _focusActionSerial = 0, _focusActionEpoch = 0, _lastFocusActionOrder = 0;
  List<Json> _focusActions = const [];
  List<Json> get focusActions => _focusActions;

  List<Json> takeFocusActions(List<int> renderedSequences) {
    if (_disposed || !_attached || !_visible || !_foreground || !ready) {
      return const [];
    }
    final rendered = renderedSequences.toSet();
    final actions = _focusActions
        .where((action) => rendered.contains(action['sequence']))
        .toList(growable: false);
    final taken = actions.map((action) => action['sequence']).toSet();
    _focusActions = List.unmodifiable(
      _focusActions.where((action) => !taken.contains(action['sequence'])),
    );
    return actions;
  }

  void _clearFocusActions() {
    _resolvedScrollActionId = _lastScrollActionId;
    _scrollActions = const [];
    _focusActionEpoch++;
    _focusActions = const [];
  }

  void _acceptFocusActions(Iterable<Json> responses) {
    if (_disposed || !_attached || !_visible || !_foreground) return;
    final received = <Json>[];
    var lastOrder = _lastFocusActionOrder;
    for (final result in responses) {
      final raw = result['focusActions'];
      if (raw == null) continue;
      if (raw is! List || raw.length > 128) {
        throw FormatException(tr("Invalid document focus action batch."));
      }
      for (final item in raw) {
        if (item is! Map) {
          throw FormatException(tr("Invalid document focus action."));
        }
        final action = obj(item);
        final id = action['controlId'];
        final order = action['actionOrder'];
        if (!const {'focus', 'blur'}.contains(action['kind']) ||
            id is! String ||
            !RegExp(r'^pirc-[1-9][0-9]{0,15}$').hasMatch(id) ||
            action['preventScroll'] is! bool ||
            order is! int ||
            order <= lastOrder ||
            order > 9007199254740991) {
          throw FormatException(tr("Invalid document focus owner or options."));
        }
        lastOrder = order;
        received.add(action);
      }
    }
    if (received.length > 128) {
      throw FormatException(tr("Too many document focus actions."));
    }
    if (received.isEmpty) return;
    _lastFocusActionOrder = lastOrder;
    // The new synchronous JS transition supersedes an older unpainted command.
    _focusActions = List.unmodifiable([
      for (final action in received)
        Map<String, dynamic>.unmodifiable({
          ...action,
          'sequence': ++_focusActionSerial,
        }),
    ]);
  }

  int _lastScrollActionId = 0;
  int _resolvedScrollActionId = 0;
  int get resolvedScrollActionId => _resolvedScrollActionId;
  List<Json> _scrollActions = const [];
  List<Json> get scrollActions => _scrollActions;

  List<Json> takeScrollActions() {
    if (_disposed || !_attached || !_visible || !_foreground || !ready) {
      return const [];
    }
    final actions = _scrollActions;
    if (actions.isNotEmpty) {
      _resolvedScrollActionId = actions.last['actionId'] as int;
    }
    _scrollActions = const [];
    return actions;
  }

  void _acceptScrollActions(Iterable<Json> responses) {
    if (_disposed || !_attached || !_visible || !_foreground) return;
    final received = <Json>[];
    var lastId = _lastScrollActionId;
    for (final response in responses) {
      final raw = response['scrollActions'];
      if (raw == null) continue;
      if (raw is! List || raw.length > 128) {
        throw FormatException(tr("Invalid document scroll action batch."));
      }
      for (final value in raw) {
        if (value is! Map) {
          throw FormatException(tr("Invalid scroll action."));
        }
        final action = obj(value);
        final id = action['actionId'];
        bool coordinate(dynamic value) =>
            value == null || (value is num && value.isFinite);
        if (id is! int ||
            id <= lastId ||
            id > _maxSafeScriptId ||
            !const {'to', 'by'}.contains(action['kind']) ||
            !const {'auto', 'instant', 'smooth'}.contains(action['behavior']) ||
            (action.containsKey('resolvedBehavior') &&
                (action['behavior'] != 'auto' ||
                    !const {
                      'instant',
                      'smooth',
                    }.contains(action['resolvedBehavior']))) ||
            (action.containsKey('elementId') &&
                (action['elementId'] is! String ||
                    !RegExp(
                      r'^pirc-[1-9][0-9]*$',
                    ).hasMatch(action['elementId'] as String))) ||
            !coordinate(action['x']) ||
            !coordinate(action['y'])) {
          throw FormatException(tr("Invalid document scroll options."));
        }
        lastId = id;
        received.add(Map<String, dynamic>.unmodifiable(action));
      }
    }
    if (_scrollActions.length + received.length > 128) {
      throw FormatException(tr("Too many document scroll actions."));
    }
    if (received.isEmpty) return;
    _lastScrollActionId = lastId;
    _scrollActions = List.unmodifiable([..._scrollActions, ...received]);
  }

  int _filePickerGeneration = 0;
  int _filePickerActionSerial = 0;
  int _lastFilePickerActionId = 0;
  List<Json> _filePickerActions = const [];
  List<Json> get filePickerActions => _filePickerActions;
  final Map<int, _PendingFilePickerAction> _filePickerInFlight = {};
  int _filePickerActivationGeneration = -1;
  double _filePickerActivationExpiresAt = double.negativeInfinity;
  static const double _filePickerActivationWindowMs = 5000;
  static const int _maxFilePickerActions = 32;
  String? _locationUrl, _queuedLocationUrl;
  String? _lastHistorySnapshot;

  List<Json> takeNavigationActions(List<int> renderedSequences) {
    if (!_attached || _disposed || !_visible || !_foreground) return const [];
    final rendered = renderedSequences.toSet();
    final current = _navigationActions
        .where((action) => rendered.contains(action['sequence']))
        .toList(growable: false);
    final consumed = current.map((action) => action['sequence']).toSet();
    _navigationActions = List.unmodifiable(
      _navigationActions.where(
        (action) => !consumed.contains(action['sequence']),
      ),
    );
    return current;
  }

  bool _sameWindowNavigation(Json action) =>
      action['kind'] != 'history' &&
      !(action['kind'] == 'anchor' && action['download'] != null) &&
      (action['kind'] == 'reload' || action['target'] == '_self');

  String? _navigationOrigin(String? value) {
    if (value == null) return null;
    final source = value.startsWith('blob:') ? value.substring(5) : value;
    final uri = Uri.tryParse(source);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      return null;
    }
    return '${uri.scheme}://${uri.host}:${uri.port}';
  }

  void _acceptNavigationActions(
    Iterable<Json> responses, {
    required bool allowPopups,
  }) {
    final received = <Json>[];
    for (final result in responses) {
      final raw = result['navigationActions'];
      if (raw == null) continue;
      if (raw is! List || raw.length > 128) {
        throw FormatException(tr("Invalid navigation action batch."));
      }
      for (final item in raw) {
        if (item is! Map) {
          throw FormatException(tr("Invalid navigation action."));
        }
        final action = obj(item);
        final kind = action['kind'];
        if (kind == 'anchor') {
          final url = action['url'];
          final parsed = url is String ? Uri.tryParse(url) : null;
          final download = action['download'];
          final target = action['target'];
          final policy = action['referrerPolicy'];
          if (parsed == null ||
              !const {
                'http',
                'https',
                'blob',
                'data',
              }.contains(parsed.scheme) ||
              (const {'http', 'https'}.contains(parsed.scheme) &&
                  parsed.host.isEmpty) ||
              download != null && download is! String ||
              parsed.scheme == 'data' && download == null ||
              target is! String ||
              policy is! String ||
              !const {
                '',
                'no-referrer',
                'no-referrer-when-downgrade',
                'origin',
                'origin-when-cross-origin',
                'same-origin',
                'strict-origin',
                'strict-origin-when-cross-origin',
                'unsafe-url',
              }.contains(policy) ||
              action['noreferrer'] is! bool ||
              action['noopener'] is! bool ||
              action['replace'] != false) {
            throw FormatException(tr("Invalid anchor activation."));
          }
          if (download != null &&
              const {'http', 'https'}.contains(parsed.scheme) &&
              _navigationOrigin(url) != _navigationOrigin(_locationUrl)) {
            action['download'] = null;
          }
          var effectiveTarget = target;
          if (RegExp(r'[\t\n\r<]').hasMatch(effectiveTarget)) {
            effectiveTarget = '_blank';
          }
          final keyword = effectiveTarget.toLowerCase();
          if (const {'', '_self', '_parent', '_top'}.contains(keyword)) {
            effectiveTarget = '_self';
          }
          if (keyword == '_blank' ||
              action['noopener'] == true && effectiveTarget != '_self' ||
              action['noreferrer'] == true && effectiveTarget != '_self') {
            effectiveTarget = '_blank';
          }
          if (action['download'] != null) effectiveTarget = '_self';
          action['target'] = effectiveTarget;
          final captured = action['capturedBlob'];
          if (captured != null) {
            if (captured is! Map ||
                parsed.scheme != 'blob' ||
                _navigationOrigin(url) == null ||
                _navigationOrigin(url) != _navigationOrigin(_locationUrl)) {
              throw FormatException(tr("Invalid captured anchor Blob owner."));
            }
            NativeDocumentBlob.fromBridge(url as String, obj(captured));
          }
          if (effectiveTarget != '_self' && !allowPopups) continue;
        } else if (kind == 'navigate') {
          final url = action['url'];
          final parsed = url is String ? Uri.tryParse(url) : null;
          if (parsed == null ||
              !const {'http', 'https', 'blob'}.contains(parsed.scheme) ||
              (parsed.scheme != 'blob' && parsed.host.isEmpty) ||
              action['replace'] is! bool ||
              !const {'_self', '_blank'}.contains(action['target'])) {
            throw FormatException(tr("Invalid navigation URL or target."));
          }
        } else if (kind == 'history') {
          final method = action['method'];
          final revision = action['revision'];
          final order = action['actionOrder'];
          if (action['target'] != '_self' ||
              order is! int ||
              order < 1 ||
              order > 9007199254740991 ||
              !const {'push', 'replace', 'go', 'scroll'}.contains(method)) {
            throw FormatException(tr("Invalid history action."));
          }
          if (method == 'go') {
            final delta = action['delta'];
            final index = action['index'];
            if (delta is! int ||
                delta < -2147483648 ||
                delta > 2147483647 ||
                delta != 0 &&
                    (index is! int || index < 0 || index > 9007199254740991)) {
              throw FormatException(tr("Invalid history delta."));
            }
          } else {
            if (revision is! int ||
                revision < 1 ||
                revision > 9007199254740991 ||
                !const {
                  'auto',
                  'manual',
                }.contains(action['scrollRestoration'])) {
              throw FormatException(
                tr("Invalid history revision or scrolling."),
              );
            }
            if (method != 'scroll') {
              if (action.containsKey('initialScrollSnapshotPending') &&
                      action['initialScrollSnapshotPending'] is! bool ||
                  action.containsKey('sourceScrollTop') &&
                      (action['sourceScrollTop'] is! num ||
                          !(action['sourceScrollTop'] as num).isFinite)) {
                throw FormatException(
                  tr("Invalid initial History scroll snapshot."),
                );
              }
              final url = action['url'];
              final key = action['entryKey'];
              if (url is! String ||
                  url.length > 8192 ||
                  Uri.tryParse(url)?.hasScheme != true ||
                  key is! String ||
                  key.isEmpty ||
                  key.length > 512 ||
                  action['stateGraph'] is! Map ||
                  utf8.encode(jsonEncode(action['stateGraph'])).length >
                      2 * 1024 * 1024) {
                throw FormatException(
                  tr("Invalid history URL, key, or state."),
                );
              }
            }
          }
        } else if (kind != 'reload') {
          throw FormatException(tr("Invalid navigation action kind."));
        }
        if (action['target'] == '_blank' && !allowPopups) continue;
        received.add({...action, 'sequence': ++_formActionSerial});
      }
    }
    if (!_attached || !_visible || !_foreground || received.isEmpty) return;
    final merged = [..._navigationActions, ...received];
    final self = merged.where(_sameWindowNavigation).lastOrNull;
    _navigationActions = List.unmodifiable(
      merged.where((a) => !_sameWindowNavigation(a) || identical(a, self)),
    );
    if (_navigationActions.length > 128) {
      _navigationActions = const [];
      throw FormatException(tr("Too many navigation actions."));
    }
  }

  void _acceptFilePickerActions(Iterable<Json> responses) {
    final received = <Json>[];
    final seen = <int, Json>{};
    for (final result in responses) {
      final raw = result['filePickerActions'];
      if (raw == null) continue;
      if (raw is! List || raw.length > _maxFilePickerActions) {
        throw FormatException(tr("Invalid file picker action batch."));
      }
      for (final item in raw) {
        if (item is! Map) {
          throw FormatException(tr("Invalid file picker action."));
        }
        final action = obj(item);
        final id = action['id'];
        final controlId = action['controlId'];
        final accept = action['accept'];
        final multiple = action['multiple'];
        final resetVersion = action['resetVersion'];
        final actionOrder = action['actionOrder'];
        if (action['kind'] != 'file' ||
            id is! int ||
            id <= 0 ||
            id > 9007199254740991 ||
            controlId is! String ||
            controlId.length > 40 ||
            !RegExp(r'^pirc-[1-9][0-9]{0,30}$').hasMatch(controlId) ||
            accept is! String ||
            accept.length > 4096 ||
            multiple is! bool ||
            resetVersion is! String ||
            resetVersion.length > 32 ||
            !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(resetVersion) ||
            actionOrder is! int ||
            actionOrder <= 0 ||
            actionOrder > 9007199254740991) {
          throw FormatException(tr("Invalid file picker action fields."));
        }

        final normalized = <String, dynamic>{
          'id': id,
          'kind': 'file',
          'controlId': controlId,
          'accept': accept,
          'multiple': multiple,
          'resetVersion': resetVersion,
          'actionOrder': actionOrder,
        };
        final duplicate = seen[id];
        if (duplicate != null) {
          if (!mapEquals(duplicate, normalized)) {
            throw FormatException(
              tr("Conflicting duplicate file picker action."),
            );
          }
          continue;
        }
        seen[id] = normalized;
        if (id <= _lastFilePickerActionId) continue;
        _lastFilePickerActionId = id;
        received.add(normalized);
      }
    }
    if (received.isEmpty) return;

    // A native selection request is user initiated. Runtime actions may be
    // emitted by a click handler or its queued completion, but cannot create
    // host permission from startup, timers, input/change events, or popups.
    if (_disposed ||
        !_attached ||
        !_visible ||
        !_foreground ||
        _filePickerActivationGeneration != _formActionGeneration ||
        _now >= _filePickerActivationExpiresAt) {
      return;
    }

    final available = _maxFilePickerActions - _filePickerActions.length;
    if (available <= 0) {
      throw FormatException(tr("Too many pending file picker actions."));
    }
    // One physical click can authorize only one native chooser, even if a
    // script attempted to queue several controls in the same event handler.
    final accepted = received.take(1).toList(growable: false);
    final next = <Json>[
      ..._filePickerActions,
      for (final action in accepted)
        Map<String, dynamic>.unmodifiable({
          ...action,
          'sequence': ++_filePickerActionSerial,
        }),
    ];
    _filePickerActions = List.unmodifiable(next);
    // One host click grants one native chooser request.
    _filePickerActivationExpiresAt = double.negativeInfinity;
    _filePickerActivationGeneration = -1;
  }

  /// Consume a painted action batch, allowing only one Android picker at a
  /// time. The native action ID is retained until [completeFilePicker] returns.
  List<Json> takeFilePickerActions(List<int> paintedSequences) {
    if (_disposed ||
        !ready ||
        _id == null ||
        !_attached ||
        !_visible ||
        !_foreground ||
        _filePickerInFlight.isNotEmpty) {
      return const [];
    }
    final painted = paintedSequences.toSet();
    final index = _filePickerActions.indexWhere(
      (action) => painted.contains(action['sequence']),
    );
    if (index < 0) return const [];

    final action = _filePickerActions[index];
    final id = action['id'] as int;
    final lease = _PendingFilePickerAction(
      scriptId: _id!,
      generation: _filePickerGeneration,
    );
    _filePickerInFlight[id] = lease;
    _filePickerActions = List.unmodifiable([
      ..._filePickerActions.take(index),
      ..._filePickerActions.skip(index + 1),
    ]);
    return [Map<String, dynamic>.unmodifiable(action)];
  }

  /// Return the result of a host file chooser to the owning JavaScript document.
  /// A result is accepted only for an action previously taken by the current
  /// document generation; lifecycle changes caused by Android's picker itself
  /// do not invalidate the lease.
  Future<void> completeFilePicker(
    int id, {
    List<Json>? files,
    bool cancelled = false,
    String? error,
  }) {
    final lease = _filePickerInFlight[id];
    if (lease == null ||
        _disposed ||
        !ready ||
        _id != lease.scriptId ||
        _filePickerGeneration != lease.generation) {
      return Future<void>.value();
    }
    if (id <= 0 ||
        files != null && files.length > 256 ||
        cancelled && files != null && files.isNotEmpty ||
        error != null && error.length > 2048) {
      return Future<void>.error(
        FormatException(tr("Invalid file picker result.")),
      );
    }

    final capturedFiles = files == null
        ? const <Json>[]
        : List<Json>.unmodifiable(
            files.map((file) => Map<String, dynamic>.unmodifiable(file)),
          );
    final payload = <String, dynamic>{
      'id': id,
      'files': capturedFiles,
      'cancelled': cancelled,
      'error': ?error,
    };
    _filePickerInFlight.remove(id);
    final generation = lease.generation;
    _pendingEvents++;
    final operation = _tail.then((_) async {
      try {
        if (_disposed ||
            !ready ||
            _id != lease.scriptId ||
            _filePickerGeneration != generation) {
          return;
        }
        await _run(
          '__pircDocument.filePickerResult(${jsonEncode(payload)})',
          expectedActionGeneration: _formActionGeneration,
        );
      } catch (failure) {
        await _failInteraction(failure);
      } finally {
        _pendingEvents--;
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        _schedule();
      }
    });
    _tail = operation;
    return operation;
  }

  /// Same-document history changes retain the VM but update its URL.
  Future<void> updateLocation(String url) {
    if (_disposed ||
        !ready ||
        _locationUrl == url ||
        _queuedLocationUrl == url) {
      return Future.value();
    }
    _queuedLocationUrl = url;
    final generation = _formActionGeneration;
    _pendingEvents++;
    _tail = _tail.then((_) async {
      try {
        if (_disposed ||
            !ready ||
            !_attached ||
            generation != _formActionGeneration) {
          return;
        }
        await _run(
          '__pircDocument.updateLocation(${jsonEncode({'url': url})})',
          expectedActionGeneration: generation,
        );
        _locationUrl = url;
      } catch (error) {
        await _failInteraction(error);
      } finally {
        if (_queuedLocationUrl == url) _queuedLocationUrl = null;
        _pendingEvents--;
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        _schedule();
      }
    });
    return _tail;
  }

  /// Synchronize entry identity as well as URL; identical URLs can have distinct state.
  Future<void> updateHistory(Json snapshot) {
    if (_disposed || !ready || !_attached) return Future.value();
    final encoded = jsonEncode(snapshot);
    // The matching snapshot may still be queued in the serialized VM tail.
    // Callers restoring history need its completion, not just its identity.
    if (_lastHistorySnapshot == encoded) return _tail;
    _lastHistorySnapshot = encoded;
    final generation = _formActionGeneration;
    _pendingEvents++;
    _tail = _tail.then((_) async {
      try {
        if (_disposed ||
            !ready ||
            !_attached ||
            generation != _formActionGeneration) {
          if (_lastHistorySnapshot == encoded) _lastHistorySnapshot = null;
          return;
        }
        await _run(
          '__pircDocument.updateHistory($encoded)',
          expectedActionGeneration: generation,
        );
        _locationUrl = snapshot['url'] as String?;
      } catch (failure) {
        await _failInteraction(failure);
      } finally {
        _pendingEvents--;
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        _schedule();
      }
    });
    return _tail;
  }

  /// Restore persisted native values without synthesizing user input events.
  Future<void> restoreControls(List<Json> controls) {
    if (_disposed || !ready || !_attached || controls.isEmpty) {
      return Future.value();
    }
    final encoded = jsonEncode({'controls': controls});
    final generation = _formActionGeneration;
    _pendingEvents++;
    _tail = _tail.then((_) async {
      try {
        if (_disposed ||
            !ready ||
            !_attached ||
            generation != _formActionGeneration) {
          return;
        }
        await _run(
          '__pircDocument.restoreControls($encoded)',
          expectedActionGeneration: generation,
        );
      } catch (failure) {
        await _failInteraction(failure);
      } finally {
        _pendingEvents--;
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        _schedule();
      }
    });
    return _tail;
  }

  int _formActionGeneration = 0;
  List<Json> _formActions = const [];
  List<Json> get formActions => _formActions;

  /// Atomically consume only commands still current in the painted batch.
  /// Newer commands await their own snapshot; detached/history-blocked queues
  /// are empty, so an old post-frame callback cannot revive navigation.
  List<Json> takeFormActions(List<int> renderedSequences) {
    if (!_attached || _disposed) return const [];
    final rendered = renderedSequences.toSet();
    final current = _formActions
        .where((action) => rendered.contains(action['sequence']))
        .toList(growable: false);
    acknowledgeFormActions(
      current.map((action) => action['sequence'] as int).toList(),
    );
    return current;
  }

  void acknowledgeFormActions(List<int> ids) {
    final consumed = ids.toSet();
    _formActions = List.unmodifiable(
      _formActions.where((action) => !consumed.contains(action['sequence'])),
    );
  }

  void _acceptFormActions(Iterable<Json> responses) {
    if (!_attached) return;
    final received = <Json>[];
    for (final result in responses) {
      final actions = result['formActions'];
      if (actions == null) continue;
      if (actions is! List || actions.length > 128) {
        throw FormatException(tr("Invalid form action batch."));
      }
      for (final raw in actions) {
        if (raw is! Map) throw FormatException(tr("Invalid form action."));
        final action = obj(raw);
        if (!const {'submit', 'invalid'}.contains(action['kind']) ||
            action['formId'] is! String) {
          throw FormatException(tr("Invalid form action kind or owner."));
        }
        received.add({...action, 'sequence': ++_formActionSerial});
      }
    }
    if (received.isEmpty) return;
    // A later successful submission replaces this form's planned navigation.
    // Invalid attempts do not cancel an earlier successful submission.
    final merged = [..._formActions, ...received];
    final lastSubmission = <String, int>{};
    for (final action in merged) {
      if (action['kind'] == 'submit') {
        lastSubmission[action['formId'] as String] = action['sequence'] as int;
      }
    }
    _formActions = List.unmodifiable(
      merged.where(
        (action) =>
            action['kind'] != 'submit' ||
            lastSubmission[action['formId']] == action['sequence'],
      ),
    );
    if (_formActions.length > 128) {
      _formActions = const [];
      throw FormatException(tr("Too many pending form actions."));
    }
  }

  void _coalesceSameWindowActions({int? nativeLinkDefaultOrder}) {
    bool selfForm(Json action) {
      if (action['kind'] != 'submit') return false;
      final target =
          action['targetSpecified'] == true ||
              '${action['target'] ?? ''}'.isNotEmpty
          ? '${action['target'] ?? ''}'
          : content?.baseTarget ?? '';
      return const {
        '',
        '_self',
        '_top',
        '_parent',
      }.contains(target.toLowerCase());
    }

    final forms = _formActions.where(selfForm);
    final navigations = _navigationActions.where(_sameWindowNavigation);
    final ordered = [
      ...forms,
      ...navigations,
      if (nativeLinkDefaultOrder != null)
        {'actionOrder': nativeLinkDefaultOrder},
    ].where((a) => a['actionOrder'] is int).toList();
    if (ordered.length < 2) return;
    // Browser default anchor activation runs after the click's microtasks.
    // Its native request supersedes every same-window script request in this batch.
    final latest =
        ordered.map((a) => a['actionOrder'] as int).reduce(max) +
        (nativeLinkDefaultOrder == null ? 0 : 1);
    bool superseded(Json a) =>
        a['actionOrder'] is int && (a['actionOrder'] as int) < latest;
    _formActions = List.unmodifiable(
      _formActions.where((a) => !selfForm(a) || !superseded(a)),
    );
    _navigationActions = List.unmodifiable(
      _navigationActions.where(
        (a) => !_sameWindowNavigation(a) || !superseded(a),
      ),
    );
  }

  bool get _documentHidden => !_attached || !_visible || !_appVisible;
  bool? _publishedHidden;
  final _visibilityChanges = <bool>[];
  bool _visibilityQueued = false;

  // Visibility is a lifecycle task: publish even when timers/frames are frozen.
  // Keep each edge queued so a quick hide/show still reaches both handlers.
  void _serviceVisibility() {
    if (_disposed || _id == null || _publishedHidden == null) return;
    final hidden = _documentHidden;
    final previous = _visibilityChanges.isEmpty
        ? _publishedHidden
        : _visibilityChanges.last;
    if (previous != hidden) _visibilityChanges.add(hidden);
    if (!ready || _visibilityQueued || _visibilityChanges.isEmpty) return;
    _visibilityQueued = true;
    _pendingEvents++;
    final identity = _id;
    _tail = _tail.then((_) async {
      try {
        while (!_disposed &&
            ready &&
            _id == identity &&
            _visibilityChanges.isNotEmpty) {
          final next = _visibilityChanges.first;
          await _run(
            '__pircDocument.updateVisibility(${jsonEncode({'hidden': next, 'now': _now})})',
            lifecycleOnly: true,
          );
          if (_disposed || !ready || _id != identity) break;
          _publishedHidden = next;
          _visibilityChanges.removeAt(0);
        }
      } catch (error) {
        await _failInteraction(error);
      } finally {
        _visibilityQueued = false;
        _pendingEvents--;
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        _schedule();
      }
    });
  }

  final Stopwatch _clock = Stopwatch();
  final double Function()? clockMilliseconds;
  Timer? _wake;
  double? _timerDue;
  bool _hasAnimationFrame = false;
  bool _lastPumpWasFrame = false;
  bool _attached = true,
      _visible = true,
      _foreground = true,
      _appVisible = true;
  int _pointerInputGeneration = 0;
  double _nextFrameAt = 0, _lastPumpAt = 0;
  String? _lastMarkup;
  String? _canvasTextUnavailable;
  double get _now =>
      clockMilliseconds?.call() ?? _clock.elapsedMicroseconds / 1000;

  /// Retained history documents freeze; current background windows throttle
  /// timers and suspend animation frames. Closing a document disposes its VM.
  void setActivity({
    required bool attached,
    required bool visible,
    Object? owner,
    bool preserveFilePicker = false,
  }) {
    if (_disposed || owner != null && !identical(_layoutOwner, owner)) return;
    if (_attached == attached && _visible == visible) return;
    if ((_visible && !visible) || (_attached && !attached)) {
      _pointerInputGeneration++;
      _clearFocusActions();
    }
    if (_visible && !visible) {
      _navigationActions = const [];
      _formActionGeneration++;
      _clearFilePickerActions(preserveInFlight: preserveFilePicker);
    }
    _attached = attached;
    if (!attached) {
      _cancelLayoutWaits();
      _formActions = const [];
      _navigationActions = const [];
      _formActionGeneration++;
      _clearFilePickerActions(preserveInFlight: preserveFilePicker);
    }
    _visible = visible;
    _serviceVisibility();
    unawaited(_serviceEnvironment());
    _serviceResources();
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground && !foreground) {
      _pointerInputGeneration++;
      _clearFocusActions();
    }
    _foreground = foreground;
    _appVisible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (!foreground) _cancelLayoutWaits();
    _serviceVisibility();
    unawaited(_serviceEnvironment());
    _serviceResources();
    _schedule();
  }

  void _schedule() {
    _wake?.cancel();
    _wake = null;
    if (_disposed ||
        !ready ||
        !_attached ||
        !_foreground ||
        _pendingEvents != 0 ||
        (_hostLayoutEnabled && _layoutCapture == null)) {
      return;
    }
    final now = _now;
    double? due = _timerDue;
    var frame = false;
    if (due != null && !_visible) due = max(due, _lastPumpAt + 1000);
    if (_visible && _hasAnimationFrame) {
      final frameDue = max(now, _nextFrameAt);
      // A slow frame can already be overdue by the time its snapshot returns.
      // Alternate with an overdue timer so continuous animation cannot starve it.
      final overdueTimerAfterFrame =
          due != null && due <= now && _lastPumpWasFrame;
      if (!overdueTimerAfterFrame &&
          (due == null || _nextFrameAt <= now || frameDue < due)) {
        due = frameDue;
        frame = true;
      }
    }
    if (due == null) return;
    final delay = max(0, due - now);
    _wake = Timer(Duration(microseconds: (delay * 1000).ceil()), () {
      _wake = null;
      _pump(frame);
    });
  }

  void _pump(bool frame) {
    if (_disposed || !ready || !_attached || !_foreground) return;
    _pendingEvents++;
    _tail = _tail.then((_) async {
      if (_disposed ||
          !ready ||
          !_attached ||
          !_foreground ||
          (frame && !_visible)) {
        _pendingEvents--;
        _schedule();
        return;
      }
      final oldContent = content;
      final oldCanvases = canvases;
      final oldDiagnostics = diagnostics;
      final oldActions = _formActions;
      final oldNavigation = _navigationActions;
      final oldFilePickerActions = _filePickerActions;
      final oldFocusActions = _focusActions;
      final oldScrollActions = _scrollActions;
      try {
        final now = _now;
        _lastPumpAt = now;
        _lastPumpWasFrame = frame;
        if (frame) _nextFrameAt = now + 1000 / 60;
        await _run(
          '__pircDocument.pump(${jsonEncode({'now': now, 'animationFrame': frame, 'nativeFrameSteps': _hostLayoutEnabled})})',
          // Promise jobs may mutate DOM after the previous serialized result.
          // Refresh from the current VM state before entering another task.
          checkLayoutFirst: _hostLayoutEnabled,
        );
      } catch (error) {
        await _failInteraction(error);
      } finally {
        _pendingEvents--;
        if (!_disposed &&
            _pendingEvents == 0 &&
            (!identical(oldContent, content) ||
                !identical(oldCanvases, canvases) ||
                !listEquals(oldDiagnostics, diagnostics) ||
                !identical(oldActions, _formActions) ||
                !identical(oldNavigation, _navigationActions) ||
                !identical(oldFilePickerActions, _filePickerActions) ||
                !identical(oldFocusActions, _focusActions) ||
                !identical(oldScrollActions, _scrollActions))) {
          notifyListeners();
        }
        _schedule();
      }
    });
  }

  Future<void> _failInteraction(Object error) async {
    if (_disposed) return;
    ready = false;
    modalDialogIds = const [];
    _retainLoadedHtmlImages();
    _resourceQueue.clear();
    for (final completion in _resourceCompletions) {
      _imagePool.acknowledge(completion['imageId'] as String?);
    }
    _resourceCompletions.clear();
    _navigationActions = const [];
    _formActions = const [];
    _clearFocusActions();
    _clearFilePickerActions();
    diagnostics = [
      ...diagnostics,
      tr("文件互動未完成：{0}", [_message(error)]),
    ];
    final session = _session;
    _id = null;
    _session = null;
    _wake?.cancel();
    _wake = null;
    if (session != null) await _close(session);
  }

  void _clearFilePickerActions({bool preserveInFlight = false}) {
    _filePickerActions = const [];
    if (!preserveInFlight) {
      _filePickerGeneration++;
      _filePickerInFlight.clear();
    }
    _filePickerActivationGeneration = -1;
    _filePickerActivationExpiresAt = double.negativeInfinity;
  }

  /// Whether the runtime keeps storage for this document (an HTTP(S)
  /// location). The session's storage has no other writer, so it is only
  /// read before a turn and written after one; no storage events arrive.
  bool _nativeStorage = false;
  static const _storageChunkChars = 65536;

  Future<Json> _storageCall(String method, [Json arguments = const {}]) async =>
      obj(
        jsonDecode(
          await _evaluate('__pircDocument.$method(${jsonEncode(arguments)})'),
        ),
      );

  Future<void> _storageParts(String method, String part, String text) async {
    for (var offset = 0; offset < text.length; offset += _storageChunkChars) {
      if (_disposed) return;
      await _storageCall(method, {
        'part': part,
        'text': text.substring(
          offset,
          min(offset + _storageChunkChars, text.length),
        ),
      });
    }
  }

  Future<void> _syncStorage(Json state) async {
    final metadata = Map<String, dynamic>.of(state)
      ..remove('local')
      ..remove('session');
    await _storageCall('storageSyncBegin', metadata);
    for (final area in ['local', 'session']) {
      final entries = state[area];
      if (entries is! List) {
        throw FormatException(tr("Invalid native Storage entries."));
      }
      for (final entry in entries) {
        if (_disposed) return;
        if (entry is! List ||
            entry.length != 2 ||
            entry[0] is! String ||
            entry[1] is! String) {
          throw FormatException(tr("Invalid native Storage entry."));
        }
        final key = entry[0] as String, value = entry[1] as String;
        await _storageCall('storageEntryBegin', {
          'area': area,
          'keyLength': key.length,
          'valueLength': value.length,
        });
        await _storageParts('storageEntryPart', 'key', key);
        await _storageParts('storageEntryPart', 'value', value);
        await _storageCall('storageEntryEnd');
      }
    }
    await _storageCall('storageSyncFinish');
  }

  Future<void> _refreshStorage([List<Json> operations = const []]) async {
    final session = _session;
    if (session == null) throw StateError(tr("Document was closed."));
    final state = await platform.storage(session, [
      for (final operation in operations)
        if (operation['generation'] == _storageSessionGeneration)
          ?_storageOperation(operation),
    ]);
    if (_disposed) return;
    final snapshot = _storageState(state);
    // The runtime already holds this revision: nothing to transfer.
    if (_storageStateRevision == _syncedStorageRevision) return;
    _syncedStorageRevision = _storageStateRevision;
    await _syncStorage(snapshot);
  }

  int _syncedStorageRevision = 0;

  /// The storage generation of this document's session; a write of another
  /// generation is stale.
  late final int _storageSessionGeneration = _nextStorageGeneration++;
  static int _nextStorageGeneration = 1;
  int _storageStateRevision = 0;
  DocumentStorageState? _lastStorageState;
  String _storageOrigin = 'null';

  /// The quota of each area, as `DocumentStorage.QUOTA_CHARS` in Kotlin.
  static const _storageQuotaBytes = 5 * 1024 * 1024;

  static DocumentStorageOperation? _storageOperation(Json operation) {
    final area = operation['area'];
    if (area != 'local' && area != 'session') {
      throw FormatException(tr("Invalid Storage write batch."));
    }
    final key = operation['key'], value = operation['value'];
    return switch (operation['type']) {
      'set' when key is String && value is String =>
        DocumentStorageOperation.set(area as String, key, value),
      'remove' when key is String => DocumentStorageOperation.remove(
        area as String,
        key,
      ),
      'clear' => DocumentStorageOperation.clear(area as String),
      _ => throw FormatException(tr("Invalid Storage write batch.")),
    };
  }

  /// The runtime's storage snapshot, from the session's two areas. The
  /// revision changes only when the areas do, so an unchanged snapshot is
  /// not sent again.
  Json _storageState(DocumentStorageState state) {
    final last = _lastStorageState;
    if (last == null ||
        !mapEquals(last.local, state.local) ||
        !mapEquals(last.session, state.session)) {
      _storageStateRevision++;
      _lastStorageState = state;
    }
    return {
      'generation': _storageSessionGeneration,
      'revision': _storageStateRevision,
      'origin': _storageOrigin,
      'sessionKey': null,
      'quotaBytes': _storageQuotaBytes,
      'local': [
        for (final MapEntry(:key, :value) in state.local.entries) [key, value],
      ],
      'session': [
        for (final MapEntry(:key, :value) in state.session.entries)
          [key, value],
      ],
    };
  }

  Future<void> _flushStorageWrites(Json initial, Json snapshot) async {
    if (!_nativeStorage ||
        initial['storageWritesPending'] != true &&
            snapshot['storageWritesPending'] != true) {
      return;
    }
    final header = await _storageCall('storageWritesBegin');
    final count = header['count'];
    if (count is! int || count < 0 || count > 256) {
      throw FormatException(tr("Invalid Storage write batch."));
    }
    final operations = <Json>[];
    for (var index = 0; index < count; index++) {
      if (_disposed) return;
      final info = await _storageCall('storageWriteInfo', {'index': index});
      final operation = <String, dynamic>{
        'area': info['area'],
        'type': info['type'],
        'generation': info['generation'],
      };
      for (final part in ['key', 'value', 'url']) {
        final length = info['${part}Length'];
        if (length == null) continue;
        if (length is! int || length < 0 || length > 5 * 1024 * 1024) {
          throw FormatException(tr("Invalid Storage write length."));
        }
        final text = StringBuffer();
        for (var offset = 0; offset < length; offset += _storageChunkChars) {
          final chunk = await _storageCall('storageWritePart', {
            'index': index,
            'part': part,
            'offset': offset,
          });
          final value = chunk['text'];
          if (value is! String ||
              value.length != min(_storageChunkChars, length - offset)) {
            throw FormatException(tr("Incomplete Storage write chunk."));
          }
          text.write(value);
        }
        operation[part] = text.toString();
      }
      operations.add(operation);
    }
    await _storageCall('storageWritesEnd');
    if (operations.isNotEmpty && !_disposed) await _refreshStorage(operations);
  }

  Future<Json> _cookieState([List<Json> writes = const []]) async {
    final session = _session;
    if (session == null) throw StateError(tr("Document was closed."));
    final cookie = await platform.cookies(session, [
      for (final write in writes)
        if (write['generation'] == _cookieGeneration && write['line'] is String)
          write['line'] as String,
    ]);
    if (_disposed) return {};
    return documentCookieState(
      cookie,
      url: _cookieUrl!,
      generation: _cookieGeneration,
    );
  }

  /// The cookie generation of this document's session.
  late final int _cookieGeneration = _nextStorageGeneration++;

  /// The URL the document was created with; cookies stay scoped to it when
  /// the history API changes the location.
  String? _cookieUrl;

  Future<void> _flushCookieWrites(Iterable<Json> responses) async {
    if (!_nativeCookies) return;
    final writes = <Json>[];
    for (final value in responses) {
      final batch = value['cookieWrites'] ?? const [];
      if (batch is! List ||
          batch.length > 128 ||
          batch.any((item) => item is! Map)) {
        throw FormatException(tr("Invalid document cookie writes."));
      }
      writes.addAll(batch.map(obj));
    }
    if (writes.isEmpty) return;
    // Keep the original two-batch transaction for ordinary evaluations. A
    // classic-script turn can contain more batches, so send bounded chunks
    // while preserving their parser order.
    for (var offset = 0; offset < writes.length; offset += 256) {
      if (_disposed) return;
      final batch = writes.sublist(offset, min(offset + 256, writes.length));
      final state = await _cookieState(batch);
      if (!_disposed) {
        await _evaluate('__pircDocument.syncCookies(${jsonEncode(state)})');
      }
    }
  }

  int? _classicScriptId(Json response) {
    if (!response.containsKey('classicScript') ||
        response['classicScript'] == null) {
      return null;
    }
    final raw = response['classicScript'];
    if (raw is! Map) {
      throw FormatException(tr("Invalid classic script descriptor."));
    }
    final descriptor = obj(raw);
    final id = descriptor['id'];
    if (id is! int || id <= 0 || id > _maxSafeScriptId) {
      throw FormatException(tr("Invalid classic script identity."));
    }
    return id;
  }

  int? _frameContinuationId(Json response) {
    final raw = response['frameContinuation'];
    if (raw == null) return null;
    if (raw is! Map) {
      throw FormatException(tr("Invalid native animation frame descriptor."));
    }
    final id = raw['id'];
    if (id is! int || id <= 0 || id > _maxSafeScriptId) {
      throw FormatException(tr("Invalid native animation frame identity."));
    }
    return id;
  }

  bool _classicScriptOwnerCurrent(int identity, String owner) =>
      !_disposed && _id == identity && _owner == owner;

  bool _classicScriptActivityCurrent(int identity, String owner) =>
      _classicScriptOwnerCurrent(identity, owner) && _attached && _foreground;

  Future<Json> _classicScriptControl(String method, Json arguments) async {
    final raw = jsonDecode(
      await _evaluate('__pircDocument.$method(${jsonEncode(arguments)})'),
    );
    if (raw is! Map) {
      throw FormatException(tr("Invalid classic script control result."));
    }
    return obj(raw);
  }

  static Json _oneShotResponse(Json response) {
    // Discard older heavy DOM/paint state but retain operation metadata such as
    // dispatch.defaultPrevented and nativeLinkDefaultOrder. A later snapshot
    // does not repeat those fields, and dropping them changes native defaults.
    const supersededState = {
      'html',
      'canvases',
      'stylesheets',
      'environment',
      'diagnostics',
      'imageReferences',
      'documentBaseURL',
      'fragmentTargetId',
      'fragmentTargetReady',
      'fragmentAncestorsRevealed',
      'initialRootScrollOverride',
      'now',
      'scheduler',
      'classicScript',
      'frameContinuation',
      'layout',
    };
    return Map.fromEntries(
      response.entries.where((entry) => !supersededState.contains(entry.key)),
    );
  }

  static void _rememberClassicScriptResponse(
    List<Json> responses,
    Json response,
  ) {
    // Keep one full response for the current DOM state. Earlier responses are
    // needed only for their one-shot host work and Storage pending bit.
    for (var index = 0; index < responses.length; index++) {
      responses[index] = _oneShotResponse(responses[index]);
    }
    responses.add(response);
  }

  Future<(Json, bool)> _prepareLayout(
    Json response,
    List<Json> responses,
    int identity,
    String owner,
    _NativeLayoutTurn turn, {
    bool force = false,
  }) async {
    if (!_hostLayoutEnabled) return (response, true);
    var current = response;
    var forceCapture = force;
    while (true) {
      final descriptor = current['layout'];
      if (descriptor is! Map) {
        throw FormatException(tr("Missing native layout revision."));
      }
      final revision = descriptor['revision'];
      final ids = descriptor['ids'];
      if (revision is! int ||
          revision <= 0 ||
          ids is! List ||
          ids.length > 5000 ||
          ids.any(
            (id) =>
                id is! String || !RegExp(r'^pirc-[1-9][0-9]*$').hasMatch(id),
          )) {
        throw FormatException(tr("Invalid native layout identity."));
      }
      layoutElementIds = Set.unmodifiable(ids.cast<String>());
      final changedRevision = layoutRevision != revision;
      layoutRevision = revision;
      final canPublishScroll =
          _attached &&
          _visible &&
          _foreground &&
          turn.actionGeneration == _formActionGeneration &&
          _classicScriptOwnerCurrent(identity, owner);
      final hasScrollResponses =
          canPublishScroll &&
          responses.any((entry) {
            final actions = entry['scrollActions'];
            return actions != null && (actions is! List || actions.isNotEmpty);
          });
      final pendingScroll =
          canPublishScroll && (hasScrollResponses || _scrollActions.isNotEmpty);
      if (descriptor['required'] != true && !forceCapture && !pendingScroll) {
        return (current, true);
      }
      final capture = _layoutCapture;
      if (capture == null ||
          !_attached ||
          !_foreground ||
          !_classicScriptOwnerCurrent(identity, owner) ||
          turn.frames >= 128) {
        return (current, false);
      }
      turn.frames++;
      final oldContent = content;
      _apply(jsonEncode(current), at: _now);
      if (hasScrollResponses) {
        _acceptScrollActions(responses);
        // These one-shot actions are now owned by the native queue. Removing
        // them prevents the final response merge from replaying a scrollBy.
        for (final entry in responses) {
          entry.remove('scrollActions');
        }
      }
      if (changedRevision || !identical(oldContent, content) || pendingScroll) {
        notifyListeners();
      }
      // The capture awaits the Flutter frame that consumes the scroll queue.
      // If a host has not consumed it yet, the next loop keeps RAF suspended
      // instead of publishing old coordinates as an acknowledged scroll.
      final cancelled = Completer<void>();
      _layoutWaits.add(cancelled);
      Json? packet;
      try {
        packet = await Future.any<Json?>([
          capture(revision, ++_layoutGeneration),
          cancelled.future.then<Json?>((_) => null),
        ]);
      } finally {
        _layoutWaits.remove(cancelled);
      }
      if (!_classicScriptOwnerCurrent(identity, owner) ||
          !_attached ||
          !_foreground ||
          !identical(capture, _layoutCapture) ||
          packet == null) {
        return (current, false);
      }
      current = await _classicScriptControl('updateLayout', packet);
      _validateResult(current);
      if (current['layoutAccepted'] == true &&
          identical(capture, _layoutCapture) &&
          _classicScriptOwnerCurrent(identity, owner)) {
        _layoutAccepted?.call(packet);
      }
      _rememberClassicScriptResponse(responses, current);
      forceCapture = false;
    }
  }

  Future<_ClassicScriptDrain> _drainClassicScripts(
    Json response, {
    required List<Json> responses,
    required int identity,
    required String owner,
    required int taskCount,
    required _NativeLayoutTurn layoutTurn,
  }) async {
    var current = response;
    var processed = false;
    while (true) {
      if (_frameContinuationId(current) != null) {
        // The preceding callback's serialized result predates its Promise jobs.
        // Read the VM again before deciding whether native layout is current.
        current = await _classicScriptControl('snapshot', {});
        _validateResult(current);
        _rememberClassicScriptResponse(responses, current);
      }
      final prepared = await _prepareLayout(
        current,
        responses,
        identity,
        owner,
        layoutTurn,
      );
      current = prepared.$1;
      if (!prepared.$2) {
        return _ClassicScriptDrain(
          active: false,
          processed: processed,
          yielded: false,
          taskCount: taskCount,
        );
      }
      final id = _classicScriptId(current);
      final frameId = _frameContinuationId(current);
      if (id == null && frameId != null) {
        if (!_visible ||
            _publishedHidden == true ||
            _visibilityChanges.isNotEmpty) {
          return _ClassicScriptDrain(
            active: false,
            processed: processed,
            yielded: false,
            taskCount: taskCount,
          );
        }
        if (taskCount >= _maxClassicScriptsPerTurn) {
          return _ClassicScriptDrain(
            active: true,
            processed: processed,
            yielded: true,
            taskCount: taskCount,
          );
        }
        if (!_classicScriptActivityCurrent(identity, owner)) {
          return _ClassicScriptDrain(
            active: false,
            processed: processed,
            yielded: false,
            taskCount: taskCount,
          );
        }
        taskCount++;
        current = await _classicScriptControl('continueAnimationFrame', {
          'id': frameId,
        });
        if (!_classicScriptOwnerCurrent(identity, owner)) {
          return _ClassicScriptDrain(
            active: false,
            processed: true,
            yielded: false,
            taskCount: taskCount,
          );
        }
        _validateResult(current);
        _rememberClassicScriptResponse(responses, current);
        processed = true;
        continue;
      }
      if (id == null) {
        return _ClassicScriptDrain(
          active: true,
          processed: processed,
          yielded: false,
          taskCount: taskCount,
        );
      }
      if (id <= _lastClassicScriptId) {
        throw FormatException(tr("Repeated classic script identity."));
      }
      if (taskCount >= _maxClassicScriptsPerTurn) {
        return _ClassicScriptDrain(
          active: true,
          processed: processed,
          yielded: true,
          taskCount: taskCount,
        );
      }
      if (!_classicScriptActivityCurrent(identity, owner)) {
        return _ClassicScriptDrain(
          active: false,
          processed: processed,
          yielded: false,
          taskCount: taskCount,
        );
      }

      final begun = await _classicScriptControl('beginClassicScript', {
        'id': id,
      });
      if (!_classicScriptOwnerCurrent(identity, owner)) {
        return _ClassicScriptDrain(
          active: false,
          processed: processed,
          yielded: false,
          taskCount: taskCount,
        );
      }
      final source = begun['source'];
      if (begun['id'] != id || source is! String) {
        throw FormatException(tr("Invalid classic script source."));
      }
      // beginClassicScript is idempotent for the still-pending ID. If activity
      // changed during that platform round trip, leave it pending for a later
      // scheduler turn without evaluating its source in the background.
      if (!_classicScriptActivityCurrent(identity, owner)) {
        return _ClassicScriptDrain(
          active: false,
          processed: processed,
          yielded: false,
          taskCount: taskCount,
        );
      }

      final evalSource =
          '$source\n;__pircDocument.endClassicScriptTurn($id);void 0;';
      if (utf8.encode(evalSource).length > _maxClassicScriptBytes) {
        throw FormatException(tr("Classic script source exceeds 4 MiB."));
      }
      if (id <= _lastClassicScriptId) {
        throw FormatException(tr("Repeated classic script identity."));
      }
      _lastClassicScriptId = id;
      taskCount++;
      String? scriptError;
      try {
        // This string is intentionally sent to the engine unchanged as a
        // top-level script, preserving global lexical declarations.
        await _evaluate(evalSource);
      } on PlatformException catch (error) {
        if (error.code != 'SCRIPT_EVALUATION') rethrow;
        final message = _message(error);
        scriptError = message.length <= _maxClassicScriptErrorChars
            ? message
            : message.substring(0, _maxClassicScriptErrorChars);
      }
      if (!_classicScriptOwnerCurrent(identity, owner)) {
        return _ClassicScriptDrain(
          active: false,
          processed: true,
          yielded: false,
          taskCount: taskCount,
        );
      }
      if (scriptError != null) {
        // Some engines skip their microtask checkpoint when a raw script throws.
        // A separate successful evaluation lets queued jobs run before finish
        // restores currentScript, while keeping the authored script top-level.
        await _evaluate('void 0;');
        if (!_classicScriptOwnerCurrent(identity, owner)) {
          return _ClassicScriptDrain(
            active: false,
            processed: true,
            yielded: false,
            taskCount: taskCount,
          );
        }
      }

      final finished = await _classicScriptControl('finishClassicScript', {
        'id': id,
        'error': ?scriptError,
      });
      if (!_classicScriptOwnerCurrent(identity, owner)) {
        return _ClassicScriptDrain(
          active: false,
          processed: true,
          yielded: false,
          taskCount: taskCount,
        );
      }
      _validateResult(finished);
      _rememberClassicScriptResponse(responses, finished);
      processed = true;
      // Validate a returned descriptor even when lifecycle activity changed;
      // if it is valid, leave it in the runtime queue for the next active turn.
      _classicScriptId(finished);
      if (!_classicScriptActivityCurrent(identity, owner)) {
        return _ClassicScriptDrain(
          active: false,
          processed: processed,
          yielded: false,
          taskCount: taskCount,
        );
      }
      current = finished;
    }
  }

  Future<_ClassicScriptDrain> _drainScriptTasks(
    Json response, {
    required List<Json> responses,
    required int identity,
    required String owner,
    required int taskCount,
    required _NativeLayoutTurn layoutTurn,
  }) async {
    var drained = await _drainClassicScripts(
      response,
      responses: responses,
      identity: identity,
      owner: owner,
      taskCount: taskCount,
      layoutTurn: layoutTurn,
    );
    while ((drained.yielded || (!drained.active && layoutTurn.frames >= 128)) &&
        _frameContinuationId(responses.last) != null &&
        _classicScriptActivityCurrent(identity, owner)) {
      // Yield Flutter/UI work without ending this guest frame's owning tail
      // operation. Queued clicks/resources must not enter between selected RAF
      // callbacks just because a bounded host chunk has finished.
      await Future<void>.delayed(Duration.zero);
      if (!_classicScriptActivityCurrent(identity, owner)) break;
      layoutTurn.frames = 0;
      drained = await _drainClassicScripts(
        responses.last,
        responses: responses,
        identity: identity,
        owner: owner,
        taskCount: 0,
        layoutTurn: layoutTurn,
      );
    }
    return drained;
  }

  static Json _mergeClassicScriptResponses(Iterable<Json> responses) {
    final merged = <String, dynamic>{};
    for (final response in responses) {
      for (final entry in response.entries) {
        final key = entry.key;
        if (key == 'classicScript') continue;
        if (_oneShotResponseFields.contains(key)) {
          final value = entry.value;
          if (value == null) continue;
          final previous = merged[key];
          if (value is List && (previous == null || previous is List)) {
            merged[key] = [...(previous as List? ?? const []), ...value];
          } else if (!merged.containsKey(key)) {
            merged[key] = value;
          }
          continue;
        }
        if (key == 'storageWritesPending') {
          merged[key] = merged[key] == true || entry.value == true;
          continue;
        }
        merged[key] = entry.value;
      }
    }
    return merged;
  }

  Future<Json> _run(
    String expression, {
    void Function(Json)? onInitialResult,
    int? expectedActionGeneration,
    int? expectedFocusEpoch,
    bool allowPopups = false,
    bool refreshLayoutFirst = false,
    bool checkLayoutFirst = false,
    bool lifecycleOnly = false,
  }) async {
    final actionGeneration = expectedActionGeneration ?? _formActionGeneration;
    final focusEpoch = expectedFocusEpoch ?? _focusActionEpoch;
    final identity = _id;
    final owner = _owner;
    if (identity == null) throw StateError(tr("Document was closed."));
    if (_nativeStorage && ready) await _refreshStorage();
    if (_nativeCookies && ready) {
      final state = await _cookieState();
      if (_disposed) return {};
      await _evaluate('__pircDocument.syncCookies(${jsonEncode(state)})');
    }
    final responses = <Json>[];
    final layoutTurn = _NativeLayoutTurn(actionGeneration);
    if ((refreshLayoutFirst || checkLayoutFirst) &&
        _hostLayoutEnabled &&
        ready &&
        _layoutCapture != null) {
      final preceding = obj(
        jsonDecode(await _evaluate('__pircDocument.snapshot()')),
      );
      _validateResult(preceding);
      _rememberClassicScriptResponse(responses, preceding);
      final prepared = await _prepareLayout(
        preceding,
        responses,
        identity,
        owner,
        layoutTurn,
        force: refreshLayoutFirst,
      );
      if (!prepared.$2) {
        final committed = await _commitResponses(
          responses,
          identity: identity,
          owner: owner,
          actionGeneration: actionGeneration,
          focusEpoch: focusEpoch,
          allowPopups: allowPopups,
        );
        return {...committed, 'layoutDeferred': true};
      }
    }
    final result = obj(jsonDecode(await _evaluate(expression)));
    _rememberClassicScriptResponse(responses, result);
    if (_disposed) return _mergeClassicScriptResponses(responses);
    onInitialResult?.call(result);
    _validateResult(result);
    if (lifecycleOnly) {
      // A second evaluation includes handler Promise jobs. Do not drain a
      // selected animation frame, scripts or layout while publishing activity.
      final fresh = await _classicScriptControl('snapshot', {'now': _now});
      _validateResult(fresh);
      _rememberClassicScriptResponse(responses, fresh);
      return _commitResponses(
        responses,
        identity: identity,
        owner: owner,
        actionGeneration: actionGeneration,
        focusEpoch: focusEpoch,
        allowPopups: false,
      );
    }
    var taskCount = 0;
    final initialDrain = await _drainScriptTasks(
      result,
      responses: responses,
      identity: identity,
      owner: owner,
      taskCount: taskCount,
      layoutTurn: layoutTurn,
    );
    taskCount = initialDrain.taskCount;
    if (!_classicScriptOwnerCurrent(identity, owner)) {
      return _mergeClassicScriptResponses(responses);
    }

    var snapshotValue = '';
    if (initialDrain.yielded || !initialDrain.active) {
      // finishClassicScript returns a full snapshot. Applying it here lets its
      // scheduler's zero-delay wake resume the unconsumed descriptor. Lifecycle
      // suspension still commits drained host work to its native queues; only
      // disposal/owner replacement may discard it.
      snapshotValue = jsonEncode(responses.last);
    } else {
      while (true) {
        if (!_classicScriptOwnerCurrent(identity, owner)) {
          return _mergeClassicScriptResponses(responses);
        }
        final now = _now;
        snapshotValue = await _evaluate(
          '__pircDocument.snapshot(${jsonEncode({'now': now})})',
        );
        if (!_classicScriptOwnerCurrent(identity, owner)) {
          return _mergeClassicScriptResponses(responses);
        }
        final decoded = obj(jsonDecode(snapshotValue));
        _validateResult(decoded);
        _rememberClassicScriptResponse(responses, decoded);
        final drain = await _drainScriptTasks(
          decoded,
          responses: responses,
          identity: identity,
          owner: owner,
          taskCount: taskCount,
          layoutTurn: layoutTurn,
        );
        taskCount = drain.taskCount;
        if (!_classicScriptOwnerCurrent(identity, owner)) {
          return _mergeClassicScriptResponses(responses);
        }
        if (drain.yielded || !drain.active) {
          snapshotValue = jsonEncode(responses.last);
          break;
        }
        if (!drain.processed) break;
      }
    }

    if (!_classicScriptOwnerCurrent(identity, owner)) {
      return _mergeClassicScriptResponses(responses);
    }
    final aggregate = _mergeClassicScriptResponses(responses);
    // _run returns the initiating operation's outcome. Follow-up snapshots may
    // include unrelated defaults (including in older hosts); they must never
    // replace click cancellation/default handling or its action ordering.
    for (final key in const [
      'defaultPrevented',
      'defaultHandled',
      'nativeLinkDefaultOrder',
      'error',
      'id',
      'type',
    ]) {
      if (result.containsKey(key)) aggregate[key] = result[key];
    }
    return _commitResponses(
      responses,
      identity: identity,
      owner: owner,
      actionGeneration: actionGeneration,
      focusEpoch: focusEpoch,
      allowPopups: allowPopups,
      aggregate: aggregate,
      snapshotValue: snapshotValue,
    );
  }

  Future<Json> _commitResponses(
    List<Json> responses, {
    required int identity,
    required String owner,
    required int actionGeneration,
    required int focusEpoch,
    required bool allowPopups,
    Json? aggregate,
    String? snapshotValue,
  }) async {
    final merged = aggregate ?? _mergeClassicScriptResponses(responses);
    if (responses.isEmpty || !_classicScriptOwnerCurrent(identity, owner)) {
      return merged;
    }
    final decoded = _apply(
      snapshotValue ?? jsonEncode(responses.last),
      at: _now,
    );
    await _flushStorageWrites(merged, decoded);
    await _flushCookieWrites(responses);
    if (_disposed || !_classicScriptOwnerCurrent(identity, owner)) {
      return merged;
    }
    _acceptResources(responses);
    if (actionGeneration == _formActionGeneration) {
      if (focusEpoch == _focusActionEpoch) _acceptFocusActions(responses);
      _acceptFilePickerActions(responses);
      _acceptScrollActions(responses);
      _acceptNavigationActions(responses, allowPopups: allowPopups);
      _acceptFormActions(responses);
      final linkOrder = merged['nativeLinkDefaultOrder'];
      _coalesceSameWindowActions(
        nativeLinkDefaultOrder: linkOrder is int ? linkOrder : null,
      );
    }
    return merged;
  }

  bool loading = false, ready = false;
  List<String> modalDialogIds = const [];
  bool get hasModalDialog => ready && modalDialogIds.isNotEmpty;
  NativeHtmlDocumentContent? content;
  Map<String, NativeDocumentCanvasSnapshot> canvases = const {};
  String _lastCanvases = "[]";
  Map<String, NativeDocumentHtmlImage> htmlImages = const {};
  String _lastHtmlImages = '[]';

  void _retainLoadedHtmlImages() {
    // The VM can stop while display resources remain valid. Keep decoded
    // versions visible, but release pending/error targets to the native fallback.
    htmlImages = Map.unmodifiable({
      for (final entry in htmlImages.entries)
        if (entry.value.status == 'loaded') entry.key: entry.value,
    });
    _lastHtmlImages = '';
  }

  List<String> diagnostics = const [];

  static bool needsRuntime(NativeHtmlDocumentContent content) {
    if (!content.isHtml) return false;
    if (content.hasScripts) return true;
    return html
        .parse(content.text)
        .querySelectorAll('*')
        .any(
          (element) =>
              element.localName == 'dialog' ||
              (element.localName == 'form' &&
                  element.attributes['method']?.trim().toLowerCase() ==
                      'dialog') ||
              (const {'button', 'input'}.contains(element.localName) &&
                  element.attributes['formmethod']?.trim().toLowerCase() ==
                      'dialog') ||
              element.attributes.keys.any(
                (key) => key.toString().toLowerCase().startsWith('on'),
              ),
        );
  }

  Future<void> start({
    required String source,
    required String url,
    String? referrerPolicy,
    String? blobCreatorUrl,
    String referrer = '',
    Json? history,
  }) async {
    if (_started || _disposed) return;
    _started = true;
    loading = true;
    notifyListeners();
    try {
      final capability = await platform.capabilities();
      if (_disposed) return;
      if (!capability.supported) {
        throw StateError(capability.reason ?? tr("此裝置無法啟動文件腳本引擎。"));
      }
      // Native capacity counts isolates while their asynchronous close runs.
      await Future.wait(List<Future<void>>.of(_pendingClosures));
      if (_disposed) return;
      final opened = await platform.open();
      if (_disposed) {
        await _close(opened);
        return;
      }
      _session = opened;
      _id = opened.id;
      // The runtime keeps cookies and storage only for an HTTP(S) location.
      // Both are this session's own, kept in memory by Kotlin.
      _storageOrigin = nativeDocumentOrigin(
        url.startsWith('blob:') ? (blobCreatorUrl ?? '') : url,
      );
      _nativeCookies = _storageOrigin != 'null' && !url.startsWith('blob:');
      _cookieUrl = _nativeCookies ? url : null;
      if (capability.canvasText) {
        try {
          // Collect representative scripts, without changing the authored text.
          // Missing glyphs remain explicit when a later value needs other fonts.
          final sample = StringBuffer();
          final seen = <int>{};
          for (final rune in source.runes) {
            if (rune < 128 || !seen.add(rune)) continue;
            final value = String.fromCharCode(rune);
            if (sample.length + value.length > 4096) break;
            sample.write(value);
          }
          final prepared = obj(
            jsonDecode(
              await platform.canvasText(
                opened,
                sample: sample.toString(),
                families: [
                  'sans-serif',
                  'serif',
                  'monospace',
                  'system-ui',
                  'ui-sans-serif',
                  'ui-serif',
                  'ui-monospace',
                  tr("Arial"),
                  tr("Helvetica"),
                  tr("Helvetica Neue"),
                  tr("Times New Roman"),
                  tr("Courier New"),
                  tr("Roboto"),
                  tr("Inter"),
                ],
              ),
            ),
          );
          if (_disposed) return;
          if (prepared['ok'] != true) {
            throw FormatException(tr("Canvas text preparation failed."));
          }
        } catch (error) {
          _canvasTextUnavailable = _message(error);
        }
      }
      await platform.loadRuntime(opened);
      if (_disposed) return;
      _locationUrl = url;
      _nativeStorage = _storageOrigin != 'null';
      if (_nativeStorage) {
        await _refreshStorage();
        if (_disposed) return;
      }
      final cookieState = _nativeCookies ? await _cookieState() : null;
      if (_disposed) return;
      _clock.reset();
      _clock.start();
      final documentParser = html.HtmlParser(source)..parse();
      final documentMode = documentParser.compatMode;
      final initialEnvironment = _environment;
      final initialHidden = _documentHidden;
      _publishedHidden = initialHidden;
      _hostLayoutEnabled = _layoutCapture != null;
      await _run(
        '__pircDocument.init(${jsonEncode({'hidden': initialHidden, 'hostLayout': _hostLayoutEnabled, 'canvasTextError': _canvasTextUnavailable, 'environment': initialEnvironment.toJson(), 'html': source, 'documentMode': documentMode, 'url': url, 'cookieState': cookieState, 'referrerPolicy': referrerPolicy, 'objectUrlNonce': _objectUrlNonce, 'referrer': referrer, 'history': history, 'now': _now})})',
      );
      if (_disposed) return;
      ready = true;
      _publishedEnvironment = initialEnvironment;
      _serviceVisibility();
      unawaited(_serviceEnvironment());
      // No storage poll here: the session's storage has no other writer, and
      // it was synchronized just before init.
    } catch (error) {
      if (!_disposed) {
        modalDialogIds = const [];
        _retainLoadedHtmlImages();
        _resourceQueue.clear();
        _resourceCompletions.clear();
        _navigationActions = const [];
        _formActions = const [];
        _clearFocusActions();
        diagnostics = [
          tr("文件腳本未完成：{0}", [_message(error)]),
        ];
        final session = _session;
        _id = null;
        _session = null;
        if (session != null) await _close(session);
      }
    } finally {
      loading = false;
      if (!_startupFinished.isCompleted) _startupFinished.complete();
      if (!_disposed) {
        _serviceResources();
        notifyListeners();
        _schedule();
      }
    }
  }

  /// True prevents the native default action. Rapid taps observe prior mutations.
  Future<bool> click(String id, List<Json> controls) =>
      dispatch(id, 'click', controls);

  /// Dispatches the platform's Back/Escape request to the top modal. A
  /// cancel listener may keep it open; the platform request is still consumed.
  Future<void> requestModalClose() {
    if (_disposed || !ready || !hasModalDialog) return Future.value();
    final generation = _formActionGeneration;
    _pendingEvents++;
    final operation = _tail.then((_) async {
      try {
        if (_disposed ||
            !ready ||
            !_attached ||
            generation != _formActionGeneration ||
            !hasModalDialog) {
          return;
        }
        await _run(
          '__pircDocument.requestTopModalClose()',
          expectedActionGeneration: generation,
        );
      } catch (error) {
        await _failInteraction(error);
      } finally {
        _pendingEvents--;
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        _schedule();
      }
    });
    _tail = operation;
    return operation;
  }

  Future<bool> dispatchDetailed(
    String id,
    String type,
    List<Json> controls,
    Json eventData,
  ) => dispatch(id, type, controls, eventData: eventData);

  /// A backdrop pointerdown targets the top dialog and may then light-dismiss
  /// it. Keep both DOM steps in one script turn so cancel can veto the close.
  Future<bool> dispatchModalBackdropPointerDown(String id, Json eventData) =>
      dispatch(
        id,
        'pointerdown',
        const [],
        eventData: eventData,
        modalBackdrop: true,
      );

  /// Touch compatibility mouse events retarget after light dismissal. The
  /// original pointerup still goes to the dialog that received pointerdown.
  Future<bool> dispatchModalBackdropTouchCompatibility(
    String? id,
    Json eventData,
  ) => dispatch(
    id ?? '',
    'click',
    const [],
    eventData: eventData,
    modalTouchCompatibility: true,
  );

  Future<bool> dispatch(
    String id,
    String type,
    List<Json> controls, {
    String? submitter,
    Json? eventData,
    bool modalBackdrop = false,
    bool modalTouchCompatibility = false,
  }) {
    final capturedEventData = eventData == null
        ? null
        : Map<String, dynamic>.unmodifiable(eventData);
    // Native controls commit edits with input before change/focus notifications.
    // Those later events may have been queued before a reset or script setter;
    // replaying their captured form values would undo that newer DOM state.
    // Keep explicit click/submission snapshots for history-restored controls.
    final capturedControls =
        const {'change', 'focus', 'focusin', 'blur', 'focusout'}.contains(type)
        ? const <Json>[]
        : controls;
    final pointerGeneration = _pointerInputGeneration;
    final queuedDuringStartup = loading;
    final pointerInput =
        type.startsWith('pointer') ||
        const {
          'mouseover',
          'mouseout',
          'mouseenter',
          'mouseleave',
        }.contains(type) ||
        (eventData?.containsKey('pointerId') ?? false);
    final actionGeneration = _formActionGeneration;
    final focusEpoch = _focusActionEpoch;
    _pendingEvents++;
    final result = Completer<bool>();
    _tail = _tail.then((_) async {
      // Startup publishes DOM snapshots while waiting for native layout. A
      // visible button can receive a tap before init finishes; preserve its
      // place in this queue instead of silently dropping the interaction.
      if (queuedDuringStartup && loading && !_disposed) {
        await _startupFinished.future;
      }
      final staleStartupInput =
          queuedDuringStartup &&
          (!_attached ||
              !_visible ||
              !_foreground ||
              pointerGeneration != _pointerInputGeneration ||
              actionGeneration != _formActionGeneration);
      final stalePointer =
          pointerInput &&
          (!_attached ||
              !_visible ||
              !_foreground ||
              pointerGeneration != _pointerInputGeneration);
      if (_disposed || !ready || stalePointer || staleStartupInput) {
        _pendingEvents--;
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        result.complete(
          _disposed || loading || stalePointer || staleStartupInput,
        );
        return;
      }
      if (type == 'click' &&
          actionGeneration == _formActionGeneration &&
          _attached &&
          _visible &&
          _foreground) {
        _filePickerActivationExpiresAt = _now + _filePickerActivationWindowMs;
        _filePickerActivationGeneration = _formActionGeneration;
      }
      var prevented = false;
      try {
        final data = await _run(
          '__pircDocument.${modalBackdrop
              ? 'dispatchModalBackdropPointerDown'
              : modalTouchCompatibility
              ? 'dispatchModalBackdropTouchCompatibility'
              : 'dispatch'}(${jsonEncode({'id': id, 'type': type, 'controls': capturedControls, 'submitter': ?submitter, 'eventData': ?capturedEventData, 'now': _now})})',
          expectedActionGeneration: actionGeneration,
          expectedFocusEpoch: focusEpoch,
          allowPopups: const {'click', 'input', 'change'}.contains(type),
          onInitialResult: (data) => prevented =
              data['defaultPrevented'] == true ||
              data['defaultHandled'] == true,
        );
        if (_disposed) {
          result.complete(true);
          return;
        }
        result.complete(
          data['defaultPrevented'] == true || data['defaultHandled'] == true,
        );
      } catch (error) {
        await _failInteraction(error);
        // A rendering failure must not undo a handler's canceled default.
        result.complete(_disposed || prevented);
      } finally {
        _pendingEvents--;
        // Do not paint an old keypress over a newer native edit awaiting its
        // turn. The final snapshot incorporates the queued events in order.
        if (!_disposed && _pendingEvents == 0) notifyListeners();
        _schedule();
      }
    });
    return result.future;
  }

  Future<Json> readObjectURL(String url) =>
      _readObjectURL(url, retained: false);

  /// Host-only read for a creator retained in navigation history. The caller
  /// must bind this capability to live document, window and account ownership.
  /// Reading bytes never resumes its paused script timers or callbacks.
  Future<Json> readRetainedObjectURL(String url) =>
      _readObjectURL(url, retained: true);

  Future<Json> _readObjectURL(String url, {required bool retained}) {
    final result = Completer<Json>();
    _tail = _tail.then((_) async {
      try {
        if (_disposed || !ready || (!retained && !_attached)) {
          throw StateError(tr("Object URL document is unavailable."));
        }
        final value = await _evaluate(
          '__pircDocument.readObjectURL(${jsonEncode(url)})',
        );
        if (_disposed || !ready || (!retained && !_attached)) {
          throw StateError(tr("Object URL document changed."));
        }
        result.complete(obj(jsonDecode(value)));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<String> _evaluate(String source) async {
    final session = _session;
    if (_disposed || session == null) {
      throw StateError(tr("Document was closed."));
    }
    return platform.evaluate(session, source);
  }

  /// One network request of the document, in the old runtime's wire shape:
  /// the request as the runtime sends it, the response as it reads it. Every
  /// request goes through [_limiter], so the channel's cap holds.
  Future<Json> _resource(int identity, Json request) async {
    final session = _session;
    if (_disposed || session == null || session.id != identity) {
      throw StateError(tr("Document was closed."));
    }
    final wire = documentResourceRequest(request);
    final response = await _limiter.run(() {
      if (_disposed || _session != session) {
        throw StateError(tr("Document was closed."));
      }
      if (_cancelledResourceRequests.contains(wire.id)) {
        throw StateError(tr("The request was cancelled."));
      }
      return platform.resource(session, wire);
    }, id: wire.id);
    final body = response.body ?? Uint8List(0);
    final integrity = request['integrity'];
    if (integrity is String &&
        !documentIntegrityMatches(
          integrity,
          body,
          responseType: response.type,
        )) {
      throw StateError(tr("The resource failed its integrity check."));
    }
    return {
      'status': response.status,
      'statusText': response.statusText,
      'url': response.url,
      'headers': [
        for (final (name, value) in response.headers) [name, value],
      ],
      'bodyBytes': response.body,
      'type': response.type,
      'redirected': response.redirected,
      'mimeType': response.mimeType,
      'charset': response.charset,
      'originClean': response.originClean,
    };
  }

  static List<Json> _validateResult(Json decoded) {
    final issues = (decoded['diagnostics'] as List? ?? const [])
        .map(
          (item) =>
              item is Map ? obj(item) : <String, dynamic>{'message': '$item'},
        )
        .toList();
    if (issues.any(
      (item) => const {
        'runtime.not_initialized',
        'runtime.init_error',
        'runtime.snapshot_error',
        'runtime.output_limit',
        'runtime.input_limit',
        'runtime.invalid_input',
        'runtime.fresh_context_required',
      }.contains(item['code']),
    )) {
      throw FormatException(issues.map((item) => item['message']).join('\n'));
    }
    return issues;
  }

  Json _apply(String snapshot, {double? at}) {
    final decoded = obj(jsonDecode(snapshot));
    final issues = _validateResult(decoded);
    _acceptStyles(decoded);
    final rawModalDialogs = decoded['modalDialogIds'] ?? const [];
    if (rawModalDialogs is! List ||
        rawModalDialogs.length > 64 ||
        rawModalDialogs.any(
          (id) => id is! String || !RegExp(r'^pirc-[1-9][0-9]*$').hasMatch(id),
        )) {
      throw FormatException(tr('Invalid modal dialog state.'));
    }
    modalDialogIds = List<String>.unmodifiable(rawModalDialogs.cast<String>());
    final target = decoded['fragmentTargetId'];
    if (target != null &&
        (target is! String ||
            !RegExp(r'^pirc-[1-9][0-9]*$').hasMatch(target))) {
      throw FormatException(tr("Invalid native fragment target identity."));
    }
    fragmentTargetId = target as String?;
    final targetReady = decoded['fragmentTargetReady'];
    if (targetReady != null && targetReady is! bool) {
      throw FormatException(tr("Invalid fragment target readiness."));
    }
    fragmentTargetReady = targetReady as bool?;
    final ancestorsRevealed = decoded['fragmentAncestorsRevealed'];
    if (ancestorsRevealed != null && ancestorsRevealed is! bool) {
      throw FormatException(tr("Invalid fragment ancestor state."));
    }
    fragmentAncestorsRevealed = ancestorsRevealed == true;
    final rootOverride = decoded['initialRootScrollOverride'];
    if (rootOverride != null && rootOverride is! bool) {
      throw FormatException(tr("Invalid initial root scroll override."));
    }
    initialRootScrollOverride = rootOverride == true;
    final markup = decoded['html'];
    if (markup is! String) {
      throw FormatException(tr("Missing document HTML."));
    }
    final rawCanvases = decoded['canvases'] ?? const [];
    if (rawCanvases is! List || rawCanvases.length > 64) {
      throw FormatException(tr("Invalid document canvases."));
    }
    final encodedCanvases = jsonEncode(rawCanvases);
    Map<String, NativeDocumentCanvasSnapshot>? nextCanvases;
    if (encodedCanvases != _lastCanvases) {
      nextCanvases = {};
      for (final value in rawCanvases) {
        if (value is! Map) throw FormatException(tr("Invalid canvas."));
        final canvas = NativeDocumentCanvasSnapshot.fromJson(
          Map<String, Object?>.from(value),
        );
        if (nextCanvases.containsKey(canvas.id)) {
          throw FormatException(tr("Duplicate document canvas."));
        }
        nextCanvases[canvas.id] = canvas;
      }
    }
    final rawImages = decoded['imageReferences'] ?? const [];
    if (rawImages is! List ||
        rawImages.length > NativeDocumentImagePool.maxEntries ||
        rawImages.any((id) => id is! String)) {
      throw FormatException(tr("Invalid document image references."));
    }
    final encodedHtmlImages = jsonEncode(decoded['htmlImages'] ?? const []);
    final nextHtmlImages = encodedHtmlImages == _lastHtmlImages
        ? htmlImages
        : decodeNativeDocumentHtmlImages(
            decoded['htmlImages'],
            available: _imagePool.images.keys.toSet(),
            vectors: _imagePool.vectorImageIds,
            animated: _imagePool.animatedImageIds,
          );
    final retainedImages = rawImages.cast<String>().toSet();
    for (final image in nextHtmlImages.values) {
      if (image.imageId != null) retainedImages.add(image.imageId!);
    }
    for (final canvas in (nextCanvases ?? canvases).values) {
      for (final command in canvas.commands) {
        if (command.op == 'drawImage') {
          retainedImages.add(command.args.first as String);
        }
      }
    }
    _imagePool.retain(retainedImages);
    htmlImages = nextHtmlImages;
    _lastHtmlImages = encodedHtmlImages;
    if (_lastMarkup != markup) {
      content = NativeHtmlDocumentContent.fromBytes(
        Uint8List.fromList(utf8.encode(markup)),
        mimeType: 'text/html',
        charset: 'utf-8',
      );
      _lastMarkup = markup;
    }
    if (nextCanvases != null) {
      canvases = Map.unmodifiable(nextCanvases);
      _lastCanvases = encodedCanvases;
    }
    final scheduler = obj(decoded['scheduler']);
    final delay = scheduler['timerDelayMs'];
    _timerDue = delay is num && delay.isFinite && delay >= 0
        ? (at ?? _now) + delay
        : null;
    _hasAnimationFrame = scheduler['animationFrame'] == true;
    diagnostics = issues
        .where((item) => item['severity'] != 'info')
        .map((item) => '${item['message']}')
        .toList(growable: false);
    diagnostics = [...diagnostics, ...?_documentStyles?.diagnostics];
    return decoded;
  }

  static String _message(Object error) => error is PlatformException
      ? error.message ?? error.code
      : error.toString();
  Future<void> _close(DocumentScriptSession session) async {
    try {
      await platform.close(session);
    } catch (_) {
      /* Timeout/account changes may already have retired the isolate. */
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    modalDialogIds = const [];
    if (!_startupFinished.isCompleted) _startupFinished.complete();
    _cancelLayoutWaits();
    _layoutCapture = null;
    _layoutOwner = null;
    _imagePool.dispose();
    _resourceQueue.clear();
    _resourceCompletions.clear();
    _formActions = const [];
    _navigationActions = const [];
    _clearFocusActions();
    _clearFilePickerActions();
    _wake?.cancel();
    _wake = null;
    _clock.stop();
    WidgetsBinding.instance.removeObserver(this);
    ready = false;
    _limiter.close();
    final session = _session;
    _id = null;
    _session = null;
    if (session != null) {
      final closing = _closed = _close(session);
      _pendingClosures.add(closing);
      unawaited(closing.whenComplete(() => _pendingClosures.remove(closing)));
    }
    super.dispose();
  }
}

class _ClassicScriptDrain {
  const _ClassicScriptDrain({
    required this.active,
    required this.processed,
    required this.yielded,
    required this.taskCount,
  });

  final bool active, processed, yielded;
  final int taskCount;
}

class _PendingFilePickerAction {
  const _PendingFilePickerAction({
    required this.scriptId,
    required this.generation,
  });

  final int scriptId;
  final int generation;
}

class _NativeLayoutTurn {
  _NativeLayoutTurn(this.actionGeneration);
  final int actionGeneration;
  int frames = 0;
}
