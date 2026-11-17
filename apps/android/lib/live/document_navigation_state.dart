import '../l10n/app_i18n.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' show Random;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show PlatformException;
import '../rendering/html_document_content.dart';
import '../rendering/html_document_urls.dart';
import '../rendering/html_document_styles.dart';
import 'document_style_loading.dart';
import '../rendering/html_form_submission.dart';
import '../rendering/html_file.dart';
import '../rendering/native_html.dart';
import '../rendering/document_scroll_anchor.dart';
import '../rendering/document_fragment.dart';
import '../rendering/document_disclosures.dart';
import '../rendering/html_document_controls.dart';
import '../rendering/document_element_scroll.dart';
import 'gateway.dart';
import 'document_scripts.dart';
import 'app_document_route.dart';
import 'app_document_shell.dart';
import 'document_response_cache.dart';
import 'document_referrer.dart';
import 'document_origin.dart';
import 'document_download.dart';
import 'document_object_urls.dart';

class NativeDocumentScope extends InheritedWidget {
  const NativeDocumentScope({
    super.key,
    required super.child,
    required this.windows,
    required this.documentUrl,
    this.window,
    this.sourceIdentity,
  });
  final NativeDocumentWindows windows;
  final String? documentUrl;
  final NativeDocumentWindow? window;
  final Object? sourceIdentity;
  Object get accountIdentity => sourceIdentity ?? windows.accountIdentity;
  static NativeDocumentScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NativeDocumentScope>();
  @override
  bool updateShouldNotify(NativeDocumentScope old) =>
      old.documentUrl != documentUrl ||
      old.window != window ||
      old.windows != windows ||
      old.sourceIdentity != sourceIdentity;
}

/// Uses the live document policy and real location; authored base URLs only
/// resolve destinations and must never replace the referring page's URL.
NativeDocumentReferrer nativeDocumentReferrer(
  NativeFetchedDocument? document, {
  required String url,
  String? elementPolicy,
  bool noreferrer = false,
}) => NativeDocumentReferrer.fromDocument(
  url: url,
  source: document?.content.isHtml == true
      ? document!.scripts?.content?.text ?? document.content.text
      : '',
  headerPolicy:
      document?.headers['referrer-policy'] as String? ??
      document?.inheritedReferrerPolicy,
  elementPolicy: elementPolicy,
  noreferrer: noreferrer,
);

int _nativeHistoryEntrySequence = 0;

String _newNativeHistoryEntryKey() => 'native-${++_nativeHistoryEntrySequence}';

String _validateHistoryEntryKey(String value) {
  if (value.isEmpty ||
      value.length > 512 ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw FormatException(tr("History API entry key is invalid."));
  }
  return value;
}

Map<String, Object?> _snapshotJsonStateGraph(Map<String, Object?> graph) {
  const maxDepth = 64;
  // Every JSON container/scalar consumes at least one encoded byte. This
  // secondary cap cannot reject a graph admitted by the 2 MiB wire budget.
  const maxNodes = 2 * 1024 * 1024;
  const maxBytes = 2 * 1024 * 1024;
  const maxSafeInteger = 9007199254740991;
  final activeContainers = HashSet<Object>.identity();
  var nodeCount = 0;

  Object? copy(Object? value, int depth) {
    if (depth > maxDepth || ++nodeCount > maxNodes) {
      throw FormatException(tr("History state graph exceeds its limits."));
    }
    if (value == null || value is bool || value is String) return value;
    if (value is int) {
      if (value.abs() > maxSafeInteger) {
        throw FormatException(tr("History state integer is out of range."));
      }
      return value;
    }
    if (value is double) {
      if (!value.isFinite) {
        throw FormatException(tr("History state number must be finite."));
      }
      return value;
    }
    if (value is List) {
      if (!activeContainers.add(value)) {
        throw FormatException(tr("History state graph contains a cycle."));
      }
      try {
        return List<Object?>.unmodifiable(
          value.map((item) => copy(item, depth + 1)),
        );
      } finally {
        activeContainers.remove(value);
      }
    }
    if (value is Map) {
      if (!activeContainers.add(value)) {
        throw FormatException(tr("History state graph contains a cycle."));
      }
      try {
        final result = <String, Object?>{};
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw FormatException(
              tr("History state graph keys must be strings."),
            );
          }
          result[entry.key as String] = copy(entry.value, depth + 1);
        }
        return Map<String, Object?>.unmodifiable(result);
      } finally {
        activeContainers.remove(value);
      }
    }
    throw FormatException(tr("History state graph is not JSON data."));
  }

  final copied = copy(graph, 0);
  if (copied is! Map<String, Object?>) {
    throw FormatException(tr("History state graph must be a JSON object."));
  }
  try {
    if (utf8.encode(jsonEncode(copied)).length > maxBytes) {
      throw FormatException(tr("History state graph exceeds its size limit."));
    }
  } on FormatException {
    rethrow;
  } catch (_) {
    throw FormatException(tr("History state graph is not JSON data."));
  }
  return copied;
}

class NativeFetchedDocument {
  NativeFetchedDocument({
    required this.id,
    required this.url,
    required this.status,
    required this.bytes,
    required this.mimeType,
    required this.content,
    required this.headers,
    this.reloadRequest,
    this.blobSource,
    this.referrer = '',
    this.navigationOrigin = 'null',
    this.inheritedReferrerPolicy,
    this.navigationReferrer = const NativeDocumentReferrer(
      '',
      'strict-origin-when-cross-origin',
    ),
    this.stylesheets = const [],
    this.styleDiagnostics = const [],
    this.preparedStyles = const [],
    this.pairedOrigin = false,
  });
  final int id, status;
  final String url, mimeType;
  /// Set by the native transport from the final response URL: the bytes were
  /// served by the paired Gateway origin. Such a document is shown as inert
  /// content: no script environment, no author stylesheets, no paired-origin
  /// resources. The native script engine enforces the same rule on its own.
  final bool pairedOrigin;
  final Uint8List bytes;
  final NativeHtmlDocumentContent content;
  final Json headers;
  final NativeHtmlFormRequest? reloadRequest;
  final NativeDocumentBlobNavigationSource? blobSource;
  final String referrer;
  // The original navigation request context survives reload/history. The
  // destination's current meta/header policy applies to its outgoing links.
  final NativeDocumentReferrer navigationReferrer;
  // Source identity survives policies that suppress Referer/Origin and POST reload.
  // Reload starts a new redirect chain from this original source identity.
  final String navigationOrigin;
  // Blob navigation inherits creator policy without inventing HTTP headers.
  final String? inheritedReferrerPolicy;
  String? get blobCreatorUrl => blobSource?.creatorUrl;
  List<NativeDocumentStylesheet> stylesheets;
  List<NativePreparedDocumentStyle> preparedStyles;
  List<String> styleDiagnostics;
  List<String> renderingDiagnostics = const [];
  String? resolvedBase;
  int historyApiAckRevision = 0;
  String? historyApiLocation;
  NativeDocumentScripts? scripts;
  final scriptFileSelections = NativeHtmlScriptFileSelections();
  final historyControls = NativeHtmlHistoryController();
  final liveControls = NativeHtmlDocumentControls();
  final disclosures = NativeDocumentDisclosures();
  final viewport = NativeHtmlViewportController();
  late final fragmentTarget = NativeDocumentTargetState(url);
  late bool initialFragmentRevealPending = content.isHtml || url.contains('#');
  final scroll = NativeDocumentScrollController();
  // A view can unmount while the document/VM remains in history or another
  // browsing context. Only retiring that document discards its element offsets.
  late final elementScroll = NativeDocumentElementScrollController(
    documentOwner: this,
  );
  String get effectiveBase {
    if (resolvedBase != null) return resolvedBase!;
    final location = historyApiLocation ?? url;
    final reference = content.baseHref;
    if (reference == null) return location;
    try {
      return resolveNativeDocumentUrl(reference, url);
    } catch (_) {
      return location;
    }
  }

  void dispose() {
    scripts?.dispose();
    scriptFileSelections.clear();
    historyControls.dispose();
    liveControls.dispose();
    scroll.dispose();
    elementScroll.dispose();
  }
}

class NativeDocumentHistoryItem {
  NativeDocumentHistoryItem(
    String url,
    NativeFetchedDocument document, {
    String? entryKey,
  }) : this._(url: url, document: document, entryKey: entryKey);

  factory NativeDocumentHistoryItem.appRoute(
    String url,
    NativeAppDocumentRoute route, {
    String? entryKey,
  }) => NativeDocumentHistoryItem._(
    url: url,
    appRoute: route,
    entryKey: entryKey,
  );

  NativeDocumentHistoryItem._({
    required this.url,
    this.document,
    this.appRoute,
    String? entryKey,
  }) : entryKey = entryKey ?? _newNativeHistoryEntryKey(),
       assert((document == null) != (appRoute == null));

  String url;
  final String entryKey;
  final NativeFetchedDocument? document;
  final NativeAppDocumentRoute? appRoute;
  Map<String, Object?>? stateGraph;
  String scrollRestoration = 'auto';
  Object? appState;
  double? scrollOffset;
  // The captured position predates initial target reveal. On first traversal,
  // prefer a resolvable fragment; otherwise retain this real reading position.
  bool scrollOffsetBeforeInitialFragment = false;
  NativeHtmlControlSnapshot? formControlSnapshot;
  bool requiresHistoryRefetch = false;
}

enum NativeDocumentLoadResult { committed, retained, appRoute, failed, stale }

/// One native browsing context. History documents stay mounted by the view so
/// controls and scroll survive back/forward without automatically replaying POST.
class NativeDocumentWindow extends ChangeNotifier {
  NativeDocumentWindow(
    this.windows, {
    required this.id,
    required this.name,
    required String sourceUrl,
    required this.canReturnToSource,
    this.returnWindowId,
    this.storageOpenerKey,
  }) : sourceUrl = windows.appDocumentUrl?.call() ?? sourceUrl,
       sourceState = windows.captureAppState?.call();
  final NativeDocumentWindows windows;
  final int id;
  final int? returnWindowId;
  final String? storageOpenerKey;
  String get storageSessionKey => '${windows._storageNamespace}:$id';
  Future<void>? _storageReady;
  String? _storageStamp;

  Future<void> ensureStorageWindow([Json? boot]) =>
      _storageReady ??= _openStorageWindow(boot);

  Future<void> _openStorageWindow(Json? boot) async {
    final connection = boot ?? await windows.connection();
    if (disposed || windows.disposed) {
      throw StateError(tr("The document window is closed."));
    }
    // Older native hosts and test gateways explicitly omit this capability.
    if (connection['documentStorage'] != true) return;
    final stamp = connection['pairingStamp'] as String;
    await windows.gateway.call('documentStorageWindowOpen', {
      'pairingStamp': stamp,
      'sessionKey': storageSessionKey,
      'openerKey': ?storageOpenerKey,
    });
    _storageStamp = stamp;
  }

  Future<void> _closeStorageWindow() async {
    try {
      await _storageReady;
      final stamp = _storageStamp;
      if (stamp != null) {
        await windows.gateway.call('documentStorageWindowClose', {
          'pairingStamp': stamp,
          'sessionKey': storageSessionKey,
        });
      }
    } catch (_) {
      // Pairing retirement already discards all session namespaces.
    }
  }

  final String name;
  String sourceUrl;
  final bool canReturnToSource;
  final List<NativeDocumentHistoryItem> history = [];
  int index = -1, _generation = 0, _nextDocument = 0;
  String? _previousHistoryEntryKey;
  String _historyChangeKind = 'load';
  int _fragmentRevealRevision = 0;
  NativeDocumentHistoryItem? _pendingFragmentReveal;
  int get fragmentRevealRevision => _fragmentRevealRevision;
  bool get hasPendingFragmentReveal =>
      identical(_pendingFragmentReveal, current) && current != null;
  void acknowledgeFragmentReveal(
    NativeDocumentHistoryItem entry,
    int revision,
  ) {
    if (identical(_pendingFragmentReveal, entry) &&
        revision == _fragmentRevealRevision) {
      _pendingFragmentReveal = null;
    }
  }

  void _requestFragmentReveal() {
    _fragmentRevealRevision++;
    _pendingFragmentReveal = current;
    _historyChangeKind = 'fragment';
    if (current?.document case final document?) {
      document.fragmentTarget.navigate(current!.url);
    }
  }

  int? _pendingHistoryIndex;
  int get historyCursor => _pendingHistoryIndex ?? index;
  Object? sourceState;
  Object? Function()? captureAppState;
  bool Function()? appCanPop;
  Future<void> Function(Object state)? restoreAppState;
  Future<void> Function(NativeAppDocumentRoute route)? onAppRoute;
  Object Function()? appNavigationIdentity;
  String? Function()? appDocumentUrl;
  Future<void>? appReady;
  Future<void> Function()? beforeClose;
  void Function()? onDisposeContext;
  void setClosing(bool value) {
    if (disposed || closing == value) return;
    closing = value;
    notifyListeners();
  }

  bool get independentApp => !canReturnToSource && windows.appBuilder != null;
  Object? get appNavigation =>
      appNavigationIdentity?.call() ?? windows.appNavigationIdentity?.call();
  bool loading = false, disposed = false, closing = false;
  bool historyPostResubmissionRequired = false;
  String? error;
  NativeDocumentHistoryItem? _historyRetryEntry;
  NativeHtmlFormRequest? failedRequest;
  String? failedBase;
  NativeDocumentBlobNavigationSource? _failedBlobSource;
  NativeDocumentReferrer? _failedReferrer;
  String? _failedOrigin;
  NativeAppDocumentRoute? pendingAppRoute;
  NativeDocumentHistoryItem? get current => index < 0 ? null : history[index];
  NativeFetchedDocument? get currentDocument => current?.document;
  NativeAppDocumentRoute? get currentAppRoute => current?.appRoute;
  int get scriptHistoryLength => history.length + (canReturnToSource ? 1 : 0);
  int get scriptHistoryIndex => index + (canReturnToSource ? 1 : 0);
  String get historyChangeKind => _historyChangeKind;

  /// Immutable snapshot sent to a document script VM when it starts.
  Json get scriptHistorySnapshot => {
    if (current != null) 'entryKey': current!.entryKey,
    'url': current?.url ?? currentDocument?.url ?? sourceUrl,
    'index': scriptHistoryIndex,
    'length': scriptHistoryLength,
    if (current?.stateGraph != null)
      'stateGraph': _snapshotJsonStateGraph(current!.stateGraph!),
    'ackRevision': currentDocument?.historyApiAckRevision ?? 0,
    'scrollRestoration': current?.scrollRestoration ?? 'auto',
    'changeKind': _historyChangeKind,
    if (currentDocument case final document?) ...{
      'targetRevision': document.fragmentTarget.revision,
      'targetUrl': document.fragmentTarget.url,
      'initialFragmentRevealPending': document.initialFragmentRevealPending,
    },
    if (_previousHistoryEntryKey != null)
      'previousEntryKey': _previousHistoryEntryKey,
  };

  /// Applies one synchronous History API mutation to the current script document.
  /// The entry remains attached to the same fetched document and never fetches.
  Json applyHistoryApiMutation({
    required NativeFetchedDocument document,
    required String method,
    required int revision,
    required String url,
    required Map<String, Object?> stateGraph,
    String? entryKey,
    String? scrollRestoration,
    bool? initialScrollSnapshotPending,
    double? sourceScrollTop,
  }) {
    final item = current;
    if (sourceScrollTop != null && !sourceScrollTop.isFinite) {
      throw FormatException(tr("Invalid source scroll snapshot."));
    }
    if (disposed || item == null || !identical(item.document, document)) {
      throw FormatException(tr("History API document is no longer active."));
    }
    if (revision != document.historyApiAckRevision + 1 ||
        revision <= 0 ||
        revision > 9007199254740991) {
      throw FormatException(tr("History API revision is out of sequence."));
    }
    final operation = switch (method) {
      'push' || 'pushState' => 'pushState',
      'replace' || 'replaceState' => 'replaceState',
      _ => throw FormatException(tr("Unsupported History API mutation.")),
    };
    final mode = scrollRestoration ?? item.scrollRestoration;
    if (mode != 'auto' && mode != 'manual') {
      throw FormatException(tr("Invalid history scroll restoration mode."));
    }
    final graph = _snapshotJsonStateGraph(stateGraph);
    final canonicalUrl = _resolveHistoryApiUrl(document, item.url, url);

    if (operation == 'pushState') {
      final key = entryKey == null
          ? _newNativeHistoryEntryKey()
          : _validateHistoryEntryKey(entryKey);
      if (history.any((entry) => entry.entryKey == key)) {
        throw FormatException(tr("History API entry key is already in use."));
      }
      item.scrollOffsetBeforeInitialFragment =
          initialScrollSnapshotPending ??
          (document.initialFragmentRevealPending &&
              document.scripts?.initialRootScrollOverride != true);
      _rememberScroll(
        preserveInitialFragment: true,
        sourceScrollTop: sourceScrollTop,
      );
      final pushed =
          NativeDocumentHistoryItem(canonicalUrl, document, entryKey: key)
            ..stateGraph = graph
            ..scrollRestoration = mode
            ..scrollOffset = item.scrollOffset
            ..formControlSnapshot = item.formControlSnapshot;
      _addHistoryItem(
        pushed,
        preserveInitialFragment: true,
        sourceScrollTop: sourceScrollTop,
      );
      _historyChangeKind = 'pushState';
    } else {
      if (entryKey != null &&
          _validateHistoryEntryKey(entryKey) != item.entryKey) {
        throw FormatException(tr("replaceState cannot change its entry key."));
      }
      _rememberScroll(preserveInitialFragment: true);
      item
        ..url = canonicalUrl
        ..stateGraph = graph
        ..scrollRestoration = mode;
      _historyChangeKind = 'replaceState';
    }
    _previousHistoryEntryKey = null;
    document
      ..historyApiAckRevision = revision
      ..historyApiLocation = canonicalUrl;
    notifyListeners();
    return scriptHistorySnapshot;
  }

  /// Applies `history.scrollRestoration` without changing entry identity.
  Json setHistoryScrollRestoration(
    NativeFetchedDocument document,
    String mode,
    int revision,
  ) {
    final item = current;
    if (disposed || item == null || !identical(item.document, document)) {
      throw FormatException(tr("History API document is no longer active."));
    }
    if (mode != 'auto' && mode != 'manual') {
      throw FormatException(tr("Invalid history scroll restoration mode."));
    }
    if (revision == document.historyApiAckRevision &&
        mode == item.scrollRestoration) {
      return scriptHistorySnapshot;
    }
    if (revision != document.historyApiAckRevision + 1 ||
        revision <= 0 ||
        revision > 9007199254740991) {
      throw FormatException(tr("History API revision is out of sequence."));
    }
    item.scrollRestoration = mode;
    document.historyApiAckRevision = revision;
    _historyChangeKind = 'scrollRestoration';
    _previousHistoryEntryKey = null;
    notifyListeners();
    return scriptHistorySnapshot;
  }

  String _resolveHistoryApiUrl(
    NativeFetchedDocument document,
    String baseUrl,
    String reference,
  ) {
    if (reference.length > 8192) {
      throw FormatException(tr("History API URL exceeds its size limit."));
    }
    String resolved;
    try {
      if (baseUrl.startsWith('blob:')) {
        final currentWithoutFragment = baseUrl.split('#').first;
        if (reference.isEmpty) {
          resolved = currentWithoutFragment;
        } else if (reference.startsWith('#')) {
          resolved = Uri.parse(
            currentWithoutFragment,
          ).replace(fragment: reference.substring(1)).toString();
        } else if (reference.startsWith('blob:') &&
            reference.split('#').first == currentWithoutFragment) {
          resolved = reference;
        } else {
          resolved = resolveNativeDocumentUrl(reference, baseUrl);
        }
      } else {
        resolved = resolveNativeDocumentUrl(reference, baseUrl);
      }
    } catch (_) {
      throw FormatException(tr("History API URL is invalid."));
    }
    final parsed = Uri.tryParse(resolved);
    if (parsed == null || parsed.userInfo.isNotEmpty) {
      throw FormatException(tr("History API URL is invalid."));
    }
    if (document.url.startsWith('blob:')) {
      final sourceBlob = document.url.split('#').first;
      if (!baseUrl.startsWith('blob:') ||
          baseUrl.split('#').first != sourceBlob ||
          !resolved.startsWith('blob:') ||
          resolved.split('#').first != sourceBlob) {
        throw FormatException(
          tr("Blob history API URLs may only change the fragment."),
        );
      }
      return resolved;
    }
    if ((parsed.scheme != 'http' && parsed.scheme != 'https') ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty) {
      throw FormatException(tr("History API URL scheme is unsupported."));
    }
    final source = Uri.tryParse(baseUrl);
    if (source == null ||
        source.userInfo.isNotEmpty ||
        (source.scheme != 'http' && source.scheme != 'https') ||
        parsed.scheme != source.scheme ||
        parsed.host != source.host ||
        parsed.port != source.port) {
      throw FormatException(tr("History API URL must remain same-origin."));
    }
    return resolved;
  }

  bool get canBack =>
      canReturnToSource ? historyCursor >= 0 : historyCursor > 0;
  bool get canForward => historyCursor + 1 < history.length;
  bool get mutationOutcomeUnknown => failedRequest?.method == 'POST';

  /// Refreshes the state snapshot associated with the current App entry.
  /// Document entries do not own App state.
  void captureCurrentAppState() {
    final state = captureAppState?.call() ?? windows.captureAppState?.call();
    final url = appDocumentUrl?.call() ?? windows.appDocumentUrl?.call();
    if (index < 0) {
      sourceState = state;
      sourceUrl = url ?? sourceUrl;
    } else if (current?.appRoute != null) {
      current!.appState = state;
      current!.url = url ?? current!.url;
    }
  }

  Future<NativeDocumentLoadResult> load(
    NativeHtmlFormRequest request, {
    required String baseUrl,
    bool fragmentAllowed = false,
    bool allowFragmentRemoval = false,
    bool revalidate = false,
    bool replaceCurrent = false,
    int? historyIndex,
    NativeHtmlControlSnapshot? restoredControls,
    NativeDocumentBlobNavigationSource? blobSource,
    NativeDocumentReferrer? referrer,
    String? origin,
  }) async {
    request = request.snapshot();
    final requestReferrer =
        referrer ??
        nativeDocumentReferrer(currentDocument, url: current?.url ?? sourceUrl);
    final requestOrigin =
        origin ?? nativeDocumentOrigin(current?.url ?? sourceUrl);
    final source = blobSource ?? currentDocument?.blobSource;
    final generation = ++_generation;
    _historyRetryEntry = null;
    _pendingHistoryIndex = historyIndex;
    final account = windows.accountIdentity;
    loading = true;
    error = null;
    failedRequest = null;
    _failedBlobSource = null;
    _failedReferrer = null;
    _failedOrigin = null;
    pendingAppRoute = null;
    notifyListeners();
    NativeFetchedDocument? uncommittedDocument;
    try {
      final reference = request.url.replaceAll(RegExp(r'[\t\n\r]'), '').trim();
      final absolute = reference.startsWith('blob:')
          ? reference
          : baseUrl.startsWith('blob:') && reference.startsWith('#')
          ? baseUrl.split('#').first + reference
          : '${await windows.gateway.call('resolveDocumentUrl', {'reference': request.url, 'baseUrl': baseUrl})}';
      if (!_valid(generation, account)) return NativeDocumentLoadResult.stale;
      if (fragmentAllowed &&
          current?.document != null &&
          (nativeSameDocumentFragment(absolute, current!.url) ||
              allowFragmentRemoval &&
                  !absolute.contains('#') &&
                  nativeSameDocumentFragment('$absolute#', current!.url))) {
        if (absolute == current!.url) {
          _requestFragmentReveal();
          loading = false;
          notifyListeners();
          return NativeDocumentLoadResult.committed;
        }
        _commitHistoryItem(
          NativeDocumentHistoryItem(absolute, current!.document!)
            ..scrollRestoration = current!.scrollRestoration,
          replaceCurrent: replaceCurrent,
          changeKind: 'fragment',
        );
        _requestFragmentReveal();

        loading = false;
        notifyListeners();
        return NativeDocumentLoadResult.committed;
      }
      final boot = await windows.connection();
      await ensureStorageWindow(boot);
      if (!_valid(generation, account)) return NativeDocumentLoadResult.stale;
      final isBlob = absolute.startsWith('blob:');
      final Json response;
      if (isBlob) {
        if (request.method != 'GET' || source == null) {
          throw StateError(tr("Blob navigation source is unavailable."));
        }
        final blob = await source.read(absolute);
        if (!_valid(generation, account)) return NativeDocumentLoadResult.stale;
        final type = blob.mimeType.isEmpty ? 'text/plain' : blob.mimeType;
        final mime = type.split(';').first.trim().toLowerCase();
        final charsetPart = type
            .split(';')
            .skip(1)
            .where((part) => part.trim().toLowerCase().startsWith('charset='))
            .firstOrNull;
        final rawCharset = charsetPart
            ?.trim()
            .substring('charset='.length)
            .trim();
        final charset =
            rawCharset != null &&
                rawCharset.length > 1 &&
                (rawCharset.startsWith('"') && rawCharset.endsWith('"') ||
                    rawCharset.startsWith("'") && rawCharset.endsWith("'"))
            ? rawCharset.substring(1, rawCharset.length - 1)
            : rawCharset;
        response = {
          'status': 200,
          'bytes': blob.bytes,
          'mimeType': mime,
          'charset': charset,
          'finalUrl': absolute,
          'finalMethod': 'GET',
          'headersRelevant': {
            'content-type': type,
            if (mime == 'application/octet-stream')
              'content-disposition': 'attachment',
          },
        };
      } else {
        response = await windows.responses.load(
          {
            'url': absolute,
            'baseUrl': baseUrl,
            'method': request.method,
            'body': request.body,
            if (request.bodyBytes != null) 'bodyBytes': request.bodyBytes,
            'contentType': request.contentType,
            'pairingStamp': boot['pairingStamp'],
            ...requestReferrer.requestArguments,
            'originUrl': requestOrigin,
          },
          isCurrent: () => _valid(generation, account),
          revalidate: revalidate,
        );
      }
      if (!_valid(generation, account)) return NativeDocumentLoadResult.stale;
      final status = (response['status'] as num).toInt();
      if (status == 204 || status == 205) {
        _pendingHistoryIndex = null;
        loading = false;
        notifyListeners();
        return NativeDocumentLoadResult.retained;
      }
      if (status >= 200 &&
          status < 300 &&
          documentIsAttachment(obj(response['headersRelevant']))) {
        await NativeDocumentDownload.response(
          response,
        ).save(windows.gateway, '${boot['pairingStamp']}');
        if (!_valid(generation, account)) return NativeDocumentLoadResult.stale;
        _pendingHistoryIndex = null;
        loading = false;
        notifyListeners();
        return NativeDocumentLoadResult.retained;
      }
      final data = response['bytes'];
      final bytes = data is Uint8List
          ? data
          : Uint8List.fromList((data as List).cast<int>());
      final mime = '${response['mimeType']}'.toLowerCase();
      final content = NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: mime,
        charset: response['charset'] as String?,
      );
      final finalUrl = '${response['finalUrl']}';
      final responseMethod = response['finalMethod'];
      final finalMethod =
          (responseMethod is String ? responseMethod : request.method)
              .toUpperCase();
      // Classify a Pirc shell only after its real HTTP response arrives; named
      // contexts dispatch the route through their own native App controller.
      if ((canReturnToSource && windows.onAppRoute != null) || independentApp) {
        final origin = boot['origin'] as String?;
        final route = origin == null
            ? null
            : nativePircAppDocumentRoute(
                content: content,
                status: status,
                finalMethod: finalMethod,
                canonicalUrl: finalUrl,
                appRootUrl: origin.endsWith('/') ? origin : '$origin/',
              );
        if (route != null) {
          pendingAppRoute = route;
          _commitHistoryItem(
            NativeDocumentHistoryItem.appRoute(finalUrl, route),
            replaceCurrent: replaceCurrent,
            historyIndex: historyIndex,
          );
          loading = false;
          notifyListeners();
          return NativeDocumentLoadResult.appRoute;
        }
      }
      final NativeHtmlFormRequest reloadRequest;
      if (finalMethod == 'GET') {
        reloadRequest = NativeHtmlFormRequest(
          url: finalUrl,
          method: 'GET',
          target: '',
        );
      } else if (finalMethod == 'POST') {
        reloadRequest = NativeHtmlFormRequest(
          url: finalUrl,
          method: 'POST',
          target: '',
          body: request.body,
          bodyBytes: request.bodyBytes,
          contentType: request.contentType,
        );
      } else {
        throw StateError(
          tr("Unsupported final document method: {0}", [finalMethod]),
        );
      }
      final document = NativeFetchedDocument(
        id: _nextDocument++,
        url: finalUrl,
        status: status,
        bytes: bytes,
        mimeType: mime,
        content: content,
        headers: Map.fromEntries(
          obj(response['headersRelevant']).entries.map(
            (entry) => MapEntry(entry.key.toLowerCase(), entry.value),
          ),
        ),
        reloadRequest: reloadRequest,
        blobSource: isBlob ? source : null,
        pairedOrigin: !isBlob && response['pairedOrigin'] == true,
        referrer: isBlob
            ? source!.documentReferrer
            : response['requestReferrer'] as String? ?? '',
        navigationOrigin:
            response['requestOriginSource'] as String? ?? requestOrigin,
        inheritedReferrerPolicy: isBlob ? source!.referrerPolicy : null,
        navigationReferrer: isBlob
            ? requestReferrer
            : NativeDocumentReferrer(
                response['requestReferrer'] as String? ?? '',
                response['requestReferrerPolicy'] as String? ??
                    requestReferrer.policy,
              ),
      );
      uncommittedDocument = document;
      if (restoredControls != null) {
        document.historyControls.restore(restoredControls);
      }
      if (content.baseHref != null) {
        try {
          document.resolvedBase =
              '${await windows.gateway.call('resolveDocumentUrl', {'reference': content.baseHref, 'baseUrl': document.url})}';
        } catch (_) {
          document.resolvedBase = document.url;
        }
      }
      await _prepareStyles(
        document,
        boot,
        generation,
        account,
        revalidate: revalidate,
      );
      if (!_valid(generation, account)) {
        document.dispose();
        return NativeDocumentLoadResult.stale;
      }
      _commitHistoryItem(
        NativeDocumentHistoryItem(document.url, document)
          ..formControlSnapshot = restoredControls,
        replaceCurrent: replaceCurrent,
        historyIndex: historyIndex,
        preserveCurrentEntryState: revalidate && replaceCurrent,
      );
      uncommittedDocument = null;
      loading = false;
      notifyListeners();
      return NativeDocumentLoadResult.committed;
    } catch (e) {
      uncommittedDocument?.dispose();
      if (e is PlatformException &&
          const {
            'account_changed',
            'unpaired',
          }.contains(obj(e.details)['code'])) {
        windows.invalidateNativeConnection();
      }
      if (!_valid(generation, account)) return NativeDocumentLoadResult.stale;
      _pendingHistoryIndex = null;
      loading = false;
      error = LiveController.describe(e);
      failedRequest = request;
      failedBase = baseUrl;
      _failedBlobSource = source;
      _failedReferrer = requestReferrer;
      _failedOrigin = requestOrigin;
      notifyListeners();
      return NativeDocumentLoadResult.failed;
    }
  }

  Future<void> _prepareStyles(
    NativeFetchedDocument document,
    Json boot,
    int generation,
    Object account, {
    bool revalidate = false,
  }) async {
    // A document the paired origin served is inert: it gets no author
    // stylesheets, which would be same-origin resources of that document.
    if (document.content.isHtml &&
        !document.pairedOrigin &&
        _valid(generation, account)) {
      final loadedStyles =
          await NativeDocumentStyleLoader(
            isCurrent: () => _valid(generation, account),
            fetchWithOptions: boot['documentStylesheets'] != true
                ? null
                : (reference, base, options) async => nativeStylesheetResponse(
                    obj(
                      await windows.gateway.call('documentStylesheet', {
                        'documentUrl': document.url,
                        'blobCreatorUrl': ?document.blobCreatorUrl,
                        'pairingStamp': boot['pairingStamp'],
                        'request': options.arguments(reference),
                      }),
                    ),
                  ),
            resolve: (reference, base) async =>
                '${await windows.gateway.call('resolveDocumentUrl', {'reference': reference, 'baseUrl': base})}',
            fetch: (reference, base) async => windows.responses.load(
              {
                'url': reference,
                'baseUrl': base,
                'method': 'GET',
                'resourceType': 'stylesheet',
                'initiatorUrl': document.url,
                'topLevelUrl': document.url,
                'pairingStamp': boot['pairingStamp'],
              },
              isCurrent: () => _valid(generation, account),
              revalidate: revalidate,
            ),
          ).load(
            document.content.text,
            baseUrl: document.effectiveBase,
            documentEncoding: document.content.encoding,
            documentUrl: document.url,
            referrerPolicy:
                document.headers['referrer-policy'] ??
                document.inheritedReferrerPolicy,
          );
      document.stylesheets = loadedStyles.stylesheets;
      document.preparedStyles = loadedStyles.prepared;
      document.styleDiagnostics = loadedStyles.diagnostics;
    }
  }

  bool _valid(int generation, Object account) =>
      !disposed &&
      generation == _generation &&
      account == windows.accountIdentity;

  bool get hasRelatedActiveContents =>
      name.isNotEmpty &&
          (returnWindowId == null ||
              windows.windows.any((w) => w.id == returnWindowId)) ||
      windows.windows.any((w) => w.name.isNotEmpty && w.returnWindowId == id);

  /// A workspace can unmount while this browsing context remains alive.
  /// Save its current entry before a recreated workspace reveals it again.
  void rememberCurrentDocumentState() {
    if (!disposed) _rememberScroll(cancelFragmentReveal: false);
  }

  void _rememberScroll({
    bool leavingDocument = false,
    bool cancelFragmentReveal = true,
    bool preserveInitialFragment = false,
    double? sourceScrollTop,
  }) {
    if (cancelFragmentReveal) {
      if (!preserveInitialFragment) {
        currentDocument?.initialFragmentRevealPending = false;
      }
      _pendingFragmentReveal = null;
      _fragmentRevealRevision++;
    }
    final item = current;
    if (item == null || historyPostResubmissionRequired) return;
    final document = item.document;
    if (leavingDocument) {
      item.requiresHistoryRefetch =
          hasRelatedActiveContents ||
          document?.reloadRequest?.method == 'POST' ||
          '${document?.headers['cache-control'] ?? ''}'
              .split(',')
              .any((directive) => directive.trim().toLowerCase() == 'no-store');
      if (document != null) {
        // Fragment entries belong to the same document lifecycle. Retiring
        // that document retires every sibling, whichever entry is visited next.
        for (final sibling in history) {
          if (identical(sibling.document, document)) {
            sibling.requiresHistoryRefetch = item.requiresHistoryRefetch;
          }
        }
      }
    }
    if (document == null) return;
    item.scrollOffset =
        sourceScrollTop ?? document.scroll.lastKnownOffset ?? item.scrollOffset;
    item.formControlSnapshot =
        document.historyControls.capture() ?? item.formControlSnapshot;
  }

  void _commitHistoryItem(
    NativeDocumentHistoryItem item, {
    required bool replaceCurrent,
    int? historyIndex,
    bool preserveCurrentEntryState = false,
    String changeKind = 'load',
  }) {
    _pendingHistoryIndex = null;
    if (currentDocument == null) captureCurrentAppState();
    if (historyIndex != null) {
      final target = history[historyIndex];
      final previousKey = current?.entryKey;
      _rememberScroll(
        leavingDocument:
            current?.document == null ||
            item.document == null ||
            !identical(current?.document, item.document),
      );
      historyPostResubmissionRequired = false;
      final oldDocument = target.document;
      item = _copyHistoryEntryMetadata(item, target)
        ..scrollOffset = target.scrollOffset
        ..formControlSnapshot =
            item.formControlSnapshot ?? target.formControlSnapshot
        ..requiresHistoryRefetch = item.requiresHistoryRefetch;
      history[historyIndex] = item;
      index = historyIndex;
      final freshDocument = item.document;
      if (freshDocument != null) {
        freshDocument.initialFragmentRevealPending =
            item.scrollOffset == null || item.scrollOffsetBeforeInitialFragment;
        freshDocument
          ..historyApiAckRevision =
              oldDocument?.historyApiAckRevision ??
              freshDocument.historyApiAckRevision
          ..historyApiLocation = item.url;
      }
      _previousHistoryEntryKey = previousKey;
      _historyChangeKind = 'traverse';
      if (oldDocument != null &&
          freshDocument != null &&
          oldDocument.reloadRequest?.method == 'GET' &&
          freshDocument.reloadRequest?.method == 'GET' &&
          oldDocument.url.split('#').first ==
              freshDocument.url.split('#').first) {
        // Chrome restores the new response across the same-document fragment
        // group. Keep each entry's URL/scroll while retiring the old body/VM.
        for (
          var siblingIndex = 0;
          siblingIndex < history.length;
          siblingIndex++
        ) {
          final sibling = history[siblingIndex];
          if (!identical(sibling.document, oldDocument)) continue;
          history[siblingIndex] =
              NativeDocumentHistoryItem(
                  sibling.url,
                  freshDocument,
                  entryKey: sibling.entryKey,
                )
                ..stateGraph = sibling.stateGraph
                ..scrollRestoration = sibling.scrollRestoration
                ..appState = sibling.appState
                ..scrollOffset = sibling.scrollOffset
                ..scrollOffsetBeforeInitialFragment =
                    sibling.scrollOffsetBeforeInitialFragment
                ..formControlSnapshot = sibling.formControlSnapshot
                ..requiresHistoryRefetch = sibling.requiresHistoryRefetch;
        }
      }
      if (oldDocument != null &&
          !history.any((entry) => identical(entry.document, oldDocument))) {
        oldDocument.dispose();
      }
      return;
    }
    _previousHistoryEntryKey = null;
    _historyChangeKind = changeKind;
    if (!replaceCurrent || index < 0) {
      _addHistoryItem(item);
      item.document?.historyApiLocation = item.url;
      historyPostResubmissionRequired = false;
      return;
    }
    _rememberScroll();
    historyPostResubmissionRequired = false;
    final oldEntry = current;
    if (preserveCurrentEntryState && oldEntry != null) {
      item = _copyHistoryEntryMetadata(item, oldEntry)
        ..scrollOffset = oldEntry.scrollOffset
        ..formControlSnapshot =
            item.formControlSnapshot ?? oldEntry.formControlSnapshot;
      if (item.document != null) {
        item.document!.initialFragmentRevealPending =
            item.scrollOffset == null || item.scrollOffsetBeforeInitialFragment;
        item.document!
          ..historyApiAckRevision =
              oldEntry.document?.historyApiAckRevision ?? 0
          ..historyApiLocation = item.url;
      }
    } else {
      item.scrollOffset = oldEntry?.scrollOffset;
      item.document?.historyApiLocation = item.url;
    }
    final oldDocument = current?.document;
    history[index] = item;
    if (oldDocument != null &&
        !history.any((entry) => identical(entry.document, oldDocument))) {
      oldDocument.dispose();
    }
  }

  NativeDocumentHistoryItem _copyHistoryEntryMetadata(
    NativeDocumentHistoryItem incoming,
    NativeDocumentHistoryItem source,
  ) {
    final copied = incoming.document != null
        ? NativeDocumentHistoryItem(
            incoming.url,
            incoming.document!,
            entryKey: source.entryKey,
          )
        : NativeDocumentHistoryItem.appRoute(
            incoming.url,
            incoming.appRoute!,
            entryKey: source.entryKey,
          );
    return copied
      ..stateGraph = source.stateGraph
      ..scrollOffsetBeforeInitialFragment =
          source.scrollOffsetBeforeInitialFragment
      ..scrollRestoration = source.scrollRestoration
      ..appState = source.appState
      ..requiresHistoryRefetch = incoming.requiresHistoryRefetch;
  }

  /// HTTP history restoration replaces the requested slot only after a usable
  /// response arrives. It does not append history or replay a POST request.
  Future<NativeDocumentLoadResult> traverseHistory(int next) async {
    final first = canReturnToSource ? -1 : 0;
    if (disposed ||
        closing ||
        next < first ||
        next >= history.length ||
        next == historyCursor) {
      return NativeDocumentLoadResult.retained;
    }
    if (next == index && _pendingHistoryIndex != null) {
      stop();
      return NativeDocumentLoadResult.retained;
    }
    final target = next < 0 ? null : history[next];
    final document = target?.document;
    if (document?.reloadRequest?.method == 'POST' &&
        !identical(current?.document, document)) {
      final originEntry = current;
      final noStore = '${document!.headers['cache-control'] ?? ''}'
          .split(',')
          .any((directive) => directive.trim().toLowerCase() == 'no-store');
      if (noStore) {
        _moveHistoryCursor(next);
        originEntry?.requiresHistoryRefetch = true;
        historyPostResubmissionRequired = true;
        target!.scrollOffset = 0;
        notifyListeners();
        return NativeDocumentLoadResult.committed;
      }
      return _restoreCachedPost(target!, next);
    }
    if (target == null ||
        !target.requiresHistoryRefetch ||
        document != null &&
            (identical(current?.document, document) ||
                document.reloadRequest?.method != 'GET')) {
      _moveHistoryCursor(next);
      return target?.appRoute != null
          ? NativeDocumentLoadResult.appRoute
          : NativeDocumentLoadResult.committed;
    }
    final account = windows.accountIdentity;
    final controls =
        target.formControlSnapshot ?? document?.historyControls.capture();
    final result = await load(
      NativeHtmlFormRequest(url: target.url, method: 'GET', target: ''),
      baseUrl: target.url,
      historyIndex: next,
      restoredControls: controls?.forFreshResponse(),
      blobSource: document?.blobSource,
      origin: document?.navigationOrigin ?? 'null',
      referrer:
          document?.navigationReferrer ??
          const NativeDocumentReferrer('', 'no-referrer'),
    );
    if (result == NativeDocumentLoadResult.failed &&
        !disposed &&
        account == windows.accountIdentity &&
        history.contains(target)) {
      _historyRetryEntry = target;
    }
    return result;
  }

  Future<NativeDocumentLoadResult> _restoreCachedPost(
    NativeDocumentHistoryItem target,
    int targetIndex,
  ) async {
    final generation = ++_generation;
    final account = windows.accountIdentity;
    final originEntry = current;
    final old = target.document!;
    final controls =
        target.formControlSnapshot ?? old.historyControls.capture();
    _pendingHistoryIndex = targetIndex;
    _historyRetryEntry = null;
    loading = true;
    error = null;
    failedRequest = null;
    pendingAppRoute = null;
    notifyListeners();
    NativeFetchedDocument? uncommitted;
    try {
      final boot = await windows.connection();
      await ensureStorageWindow(boot);
      if (!_valid(generation, account)) return NativeDocumentLoadResult.stale;
      final document =
          NativeFetchedDocument(
              id: _nextDocument++,
              url: old.url,
              status: old.status,
              bytes: old.bytes,
              mimeType: old.mimeType,
              content: old.content,
              headers: old.headers,
              reloadRequest: old.reloadRequest,
              referrer: old.referrer,
              navigationReferrer: old.navigationReferrer,
              navigationOrigin: old.navigationOrigin,
              inheritedReferrerPolicy: old.inheritedReferrerPolicy,
              pairedOrigin: old.pairedOrigin,
            )
            ..resolvedBase = old.resolvedBase
            ..historyApiAckRevision = old.historyApiAckRevision
            ..historyApiLocation = target.url;
      uncommitted = document;
      if (controls != null) document.historyControls.restore(controls);
      await _prepareStyles(document, boot, generation, account);
      if (!_valid(generation, account)) {
        document.dispose();
        return NativeDocumentLoadResult.stale;
      }
      _commitHistoryItem(
        NativeDocumentHistoryItem(target.url, document)
          ..formControlSnapshot = controls,
        replaceCurrent: false,
        historyIndex: targetIndex,
      );
      // Chrome's observed navigation through a POST response does not keep the
      // outgoing GET tree in BFCache, including a noopener context.
      originEntry?.requiresHistoryRefetch = true;
      uncommitted = null;
      loading = false;
      notifyListeners();
      return NativeDocumentLoadResult.committed;
    } catch (errorValue) {
      uncommitted?.dispose();
      if (errorValue is PlatformException &&
          const {
            'account_changed',
            'unpaired',
          }.contains(obj(errorValue.details)['code'])) {
        windows.invalidateNativeConnection();
      }
      if (!_valid(generation, account)) return NativeDocumentLoadResult.stale;
      _pendingHistoryIndex = null;
      loading = false;
      error = LiveController.describe(errorValue);
      notifyListeners();
      return NativeDocumentLoadResult.failed;
    }
  }

  void _addHistoryItem(
    NativeDocumentHistoryItem item, {
    bool preserveInitialFragment = false,
    double? sourceScrollTop,
  }) {
    _rememberScroll(
      sourceScrollTop: sourceScrollTop,
      preserveInitialFragment: preserveInitialFragment,
      leavingDocument:
          current?.document == null ||
          item.document == null ||
          !identical(current?.document, item.document),
    );
    final removed = history
        .skip(index + 1)
        .map((entry) => entry.document)
        .whereType<NativeFetchedDocument>()
        .toSet();
    history.removeRange(index + 1, history.length);
    for (final removedDocument in removed) {
      if (!history.any((entry) => identical(entry.document, removedDocument)) &&
          !identical(removedDocument, item.document)) {
        removedDocument.dispose();
      }
    }
    history.add(item);
    index = history.length - 1;
  }

  int get navigationGeneration => _generation;
  void stop({int? expectedGeneration}) {
    if (expectedGeneration != null && expectedGeneration != _generation) return;
    _generation++;
    _pendingHistoryIndex = null;
    pendingAppRoute = null;
    loading = false;
    notifyListeners();
  }

  void returnToSource() {
    if (!canReturnToSource || disposed) return;
    _previousHistoryEntryKey = current?.entryKey;
    _historyChangeKind = 'traverse';
    historyPostResubmissionRequired = false;
    _pendingHistoryIndex = null;
    _rememberScroll();
    _generation++;
    pendingAppRoute = null;
    loading = false;
    index = -1;
    error = null;
  }

  void back() => _moveHistoryCursor(index - 1);

  void forward() => _moveHistoryCursor(index + 1);

  void _moveHistoryCursor(int next) {
    final firstIndex = canReturnToSource ? -1 : 0;
    if (next < firstIndex || next >= history.length || next == index) return;

    _previousHistoryEntryKey = current?.entryKey;
    final targetDocument = next < 0 ? null : history[next].document;
    _rememberScroll(
      leavingDocument:
          current?.document == null ||
          targetDocument == null ||
          !identical(current?.document, targetDocument),
    );
    _historyRetryEntry = null;
    _pendingHistoryIndex = null;
    historyPostResubmissionRequired = false;
    // Advancing the generation invalidates any response or route callback that
    // was still pending when the user moved through the local history list.
    _generation++;
    loading = false;
    error = null;
    index = next;
    _historyChangeKind = 'traverse';
    currentDocument?.historyApiLocation = current?.url;
    if (currentDocument case final document?) {
      document.fragmentTarget.navigate(current!.url);
    }
    failedRequest = null;
    failedBase = null;
    pendingAppRoute = currentAppRoute;
    notifyListeners();
  }

  void dismissFailureToSource() {
    if (!canReturnToSource || index >= 0 || disposed) return;
    _generation++;
    pendingAppRoute = null;
    loading = false;
    error = null;
    failedRequest = null;
    failedBase = null;
    notifyListeners();
  }

  Future<NativeDocumentLoadResult> retryRead() async {
    final request = failedRequest;
    if (request == null || request.method != 'GET') {
      return Future.value(NativeDocumentLoadResult.retained);
    }
    final target = _historyRetryEntry;
    final retryIndex = target == null ? -1 : history.indexOf(target);
    final account = windows.accountIdentity;
    final retry = load(
      request,
      baseUrl: failedBase!,
      blobSource: _failedBlobSource,
      referrer: _failedReferrer,
      origin: _failedOrigin,
      historyIndex: retryIndex < 0 ? null : retryIndex,
      restoredControls: target?.formControlSnapshot?.forFreshResponse(),
    );
    final generation = _generation;
    final result = await retry;
    if (target != null &&
        result == NativeDocumentLoadResult.failed &&
        _valid(generation, account) &&
        history.contains(target)) {
      _historyRetryEntry = target;
    }
    return result;
  }

  void disposeDocuments() {
    _historyRetryEntry = null;
    _pendingHistoryIndex = null;
    historyPostResubmissionRequired = false;
    _generation++;
    pendingAppRoute = null;
    loading = false;
    for (final item in history.map((e) => e.document).toSet()) {
      item?.dispose();
    }
    history.clear();
    index = -1;
    sourceState = null;
    error = null;
    failedRequest = null;
    failedBase = null;
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(_closeStorageWindow());
    onDisposeContext?.call();
    disposeDocuments();
    super.dispose();
  }
}

/// Native windows are scoped to the original App connection. Pair/account
/// changes invalidate cached documents and in-flight replies before publication.
class NativeDocumentWindows extends ChangeNotifier {
  NativeDocumentWindows(
    this.gateway, {
    this.owner,
    this.onAppRoute,
    this.appNavigationIdentity,
    this.captureAppState,
    this.appCanPop,
    this.restoreAppState,
    this.appDocumentUrl,
    this.managedPresentation = false,
    this.appBuilder,
  }) {
    _identity = _readIdentity();
    owner?.addListener(_observe);
  }
  final Gateway gateway;
  Future<void> _scriptStarts = Future.value();

  /// Keep the four-isolate Android budget while allowing ordinary browsing
  /// through more than four pages. Evicted history reloads on traversal, with
  /// native control/scroll restoration, as a page absent from browser BFCache.
  Future<void> startDocumentScripts(
    NativeFetchedDocument document,
    NativeDocumentScripts scripts,
  ) {
    _scriptStarts = _scriptStarts.then((_) async {
      if (disposed) return;
      final documents = windows
          .expand((w) => w.history)
          .map((entry) => entry.document)
          .whereType<NativeFetchedDocument>()
          .toSet();
      if (!documents.contains(document) || scripts.occupiesSlot) return;
      final current = windows.map((w) => w.currentDocument).toSet();
      var occupied = documents
          .where((d) => d != document && d.scripts?.occupiesSlot == true)
          .length;
      for (final candidate in documents) {
        if (occupied < 4) break;
        final retiring = candidate.scripts;
        if (candidate == document ||
            current.contains(candidate) ||
            retiring?.occupiesSlot != true) {
          continue;
        }
        final controls = candidate.historyControls.capture();
        for (final window in windows) {
          for (final entry in window.history.where(
            (entry) => entry.document == candidate,
          )) {
            entry.formControlSnapshot = controls;
            entry.requiresHistoryRefetch = true;
          }
        }
        retiring!.dispose();
        await retiring.closed;
        occupied--;
      }
      if (!disposed) {
        NativeDocumentWindow? historyWindow;
        for (final candidate in windows) {
          if (identical(candidate.currentDocument, document)) {
            historyWindow = candidate;
            break;
          }
        }
        final historySnapshot =
            historyWindow?.scriptHistorySnapshot ??
            <String, dynamic>{
              'url': document.historyApiLocation ?? document.url,
              'index': 0,
              'length': 1,
              'ackRevision': document.historyApiAckRevision,
              'scrollRestoration': 'auto',
              'changeKind': 'load',
            };
        await historyWindow?.ensureStorageWindow();
        if (disposed || historyWindow?.disposed == true) return;
        scripts.configureStyles(
          encoding: document.content.encoding,
          prepared: document.preparedStyles,
        );
        await scripts.start(
          storageSessionKey: historyWindow?.storageSessionKey,
          source: document.content.text,
          url: historySnapshot['url'] as String? ?? document.url,
          history: historySnapshot,
          referrerPolicy:
              document.headers['referrer-policy'] ??
              document.inheritedReferrerPolicy,
          blobCreatorUrl: document.blobCreatorUrl,
          referrer: document.referrer,
        );
      }
    });
    return _scriptStarts;
  }

  NativeDocumentBlobNavigationSource? blobSourceFor(
    NativeFetchedDocument document, {
    String? url,
    String? referrerPolicy,
    bool noreferrer = false,
    NativeDocumentBlob? initialBlob,
  }) {
    final referrer = nativeBlobNavigationReferrer(
      sourceUrl: document.url,
      html: document.scripts?.content?.text ?? document.content.text,
      headerPolicy: document.headers['referrer-policy'] as String?,
      elementPolicy: referrerPolicy,
      noreferrer: noreferrer,
    );
    final existing = document.blobSource;
    if (url != null &&
        url.split('#').first == document.url.split('#').first &&
        existing != null) {
      return NativeDocumentBlobNavigationSource(
        creatorUrl: existing.creatorUrl,
        binding: existing.binding,
        referrerPolicy: existing.referrerPolicy,
        referrer: referrer,
        initialBlob: initialBlob,
      );
    }
    final scripts = document.scripts;
    if (scripts == null) return null;
    final account = accountIdentity;
    return NativeDocumentBlobNavigationSource(
      creatorUrl: document.url,
      referrer: referrer,
      referrerPolicy: nativeDocumentReferrer(
        document,
        url: document.url,
      ).policy,
      initialBlob: initialBlob,
      binding: NativeDocumentObjectUrlBinding(
        owner: scripts,
        isCurrent: () =>
            !disposed &&
            accountIdentity == account &&
            scripts.ready &&
            windows.any(
              (window) =>
                  !window.disposed &&
                  !window.closing &&
                  window.history.any(
                    (entry) => identical(entry.document, document),
                  ),
            ),
        readBytes: scripts.readRetainedObjectURL,
      ),
    );
  }

  late final responses = NativeDocumentResponseCache(
    prepare: (arguments) async =>
        obj(await gateway.call('documentPrepareRequest', arguments)),
    fetch: (arguments) async => obj(await gateway.call('document', arguments)),
  );
  final LiveController? owner;
  final Future<void> Function(NativeAppDocumentRoute route)? onAppRoute;
  final Object Function()? appNavigationIdentity;
  final Object? Function()? captureAppState;
  final bool Function()? appCanPop;
  final Future<void> Function(Object state)? restoreAppState;
  final String? Function()? appDocumentUrl;
  bool managedPresentation;
  final Widget Function(NativeDocumentWindow window)? appBuilder;
  final List<NativeDocumentWindow> windows = [];
  int? activeId;
  final String _storageNamespace =
      'window-${List.generate(4, (_) => Random.secure().nextInt(1 << 32).toRadixString(16)).join()}';
  int _nextWindow = 0, _connectionEpoch = 0;
  int selectionRevision = 0;
  late Object _identity;
  bool disposed = false;
  bool presented = false;
  String? connectionError;
  String? _anonymousStamp, _anonymousOrigin;
  Object get accountIdentity => _readIdentity();
  Object _readIdentity() => owner == null
      ? _connectionEpoch
      : (
          owner!.accountRevision,
          owner!.origin,
          owner!.clientId,
          owner!.pairingStamp,
          _connectionEpoch,
        );
  NativeDocumentWindow? get active =>
      windows.where((e) => e.id == activeId).firstOrNull;

  /// The freely selected main App may change independently of retained history.
  /// Update its virtual source entry without rewriting historical App routes.
  void captureSourceAppState() {
    if (disposed) return;
    final state = captureAppState?.call();
    final url = appDocumentUrl?.call();
    for (final window in windows.where((w) => w.canReturnToSource)) {
      window.sourceState = state;
      window.sourceUrl = url ?? window.sourceUrl;
    }
  }

  void notifyAppNavigationChanged() {
    if (!disposed) notifyListeners();
  }

  void invalidateNativeConnection() {
    if (disposed) return;
    _connectionEpoch++;
    responses.clear();
    _identity = _readIdentity();
    connectionError = tr("連線已變更，請回到 App 重新開啟內容。");
    for (final window in windows) {
      window.removeListener(notifyListeners);
      window.dispose();
    }
    windows.clear();
    activeId = null;
    notifyListeners();
  }

  void _observe() {
    final next = _readIdentity();
    if (next == _identity) return;
    _identity = next;
    responses.clear();
    connectionError = tr("連線已變更，請回到 App 重新開啟內容。");
    for (final window in windows) {
      window.removeListener(notifyListeners);
      window.dispose();
    }
    windows.clear();
    activeId = null;
    notifyListeners();
  }

  Future<Json> connection() async {
    final identity = accountIdentity;
    final data = obj(await gateway.call('boot'));
    if (disposed || accountIdentity != identity) {
      throw StateError(tr("Connection changed."));
    }
    final stamp = owner?.pairingStamp ?? data['pairingStamp'];
    if (owner == null && stamp != null) {
      if (_anonymousStamp != null &&
          (_anonymousStamp != stamp || _anonymousOrigin != data['origin'])) {
        _connectionEpoch++;
        responses.clear();
        _identity = _readIdentity();
        for (final window in windows) {
          window.removeListener(notifyListeners);
          window.dispose();
        }
        windows.clear();
        activeId = null;
        _anonymousStamp = stamp as String;
        _anonymousOrigin = data['origin'] as String?;
        connectionError = tr("連線已變更，請回到 App 重新開啟內容。");
        notifyListeners();
        throw StateError(tr("Connection changed."));
      }
      _anonymousStamp = stamp as String;
      _anonymousOrigin = data['origin'] as String?;
    }
    if (stamp == null ||
        data['pairingStamp'] != stamp ||
        (owner?.origin != null && data['origin'] != owner!.origin)) {
      throw StateError(tr("Connection changed."));
    }
    return {...data, 'pairingStamp': stamp};
  }

  NativeDocumentWindow target(
    String raw,
    NativeDocumentWindow? source, {
    required String sourceUrl,
    bool? noopener,
  }) {
    if (disposed ||
        source?.disposed == true ||
        source?.closing == true ||
        source != null && !windows.contains(source)) {
      throw StateError(tr("Connection changed."));
    }
    connectionError = null;
    var keyword = raw.toLowerCase();
    final withoutOpener = noopener ?? keyword == '_blank';
    if (withoutOpener &&
        !const {'', '_self', '_parent', '_top'}.contains(keyword)) {
      raw = '_blank';
      keyword = '_blank';
    }
    if (const {'', '_self', '_parent', '_top'}.contains(keyword) &&
        source != null) {
      return source;
    }
    if (raw.isNotEmpty && keyword != '_blank') {
      final found = windows.where((e) => e.name == raw).firstOrNull;
      if (found != null) {
        if (source == null && found.canReturnToSource && found.index == -1) {
          found.sourceUrl = appDocumentUrl?.call() ?? sourceUrl;
          found.sourceState = captureAppState?.call();
          found.notifyListeners();
        }
        return found;
      }
    }
    if (const {'', '_self', '_parent', '_top'}.contains(keyword) &&
        source == null) {
      final found = windows.where((e) => e.canReturnToSource).firstOrNull;
      if (found != null) {
        if (found.index == -1) {
          found.sourceUrl = appDocumentUrl?.call() ?? sourceUrl;
          found.sourceState = captureAppState?.call();
          found.notifyListeners();
        }
        return found;
      }
    }
    final window = NativeDocumentWindow(
      this,
      id: _nextWindow++,
      returnWindowId: source?.id,
      storageOpenerKey: withoutOpener ? null : source?.storageSessionKey,
      name: const {'_blank', '_self', '_parent', '_top', ''}.contains(keyword)
          ? ''
          : raw,
      sourceUrl: sourceUrl,
      canReturnToSource:
          source == null &&
          keyword != '_blank' &&
          const {'', '_self', '_parent', '_top'}.contains(keyword),
    );
    windows.add(window);
    window.addListener(notifyListeners);
    return window;
  }

  /// Selection intent invalidates pending navigation even when selecting the
  /// already active context. A late background response may still commit its
  /// history, but cannot take focus from a newer selection.
  bool select(NativeDocumentWindow? window, {int? expectedSelectionRevision}) {
    if (disposed ||
        expectedSelectionRevision != null &&
            expectedSelectionRevision != selectionRevision ||
        window != null &&
            (window.disposed || window.closing || !windows.contains(window))) {
      return false;
    }
    if (active != window) active?._rememberScroll();
    selectionRevision++;
    activeId = window?.id;
    notifyListeners();
    return true;
  }

  void close(NativeDocumentWindow window) {
    if (disposed || !windows.remove(window)) return;
    window.removeListener(notifyListeners);
    window.dispose();
    if (activeId == window.id) {
      selectionRevision++;
      activeId = windows
          .where((w) => w.id == window.returnWindowId && !w.closing)
          .firstOrNull
          ?.id;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    responses.clear();
    owner?.removeListener(_observe);
    for (final window in windows) {
      window.removeListener(notifyListeners);
      window.dispose();
    }
    windows.clear();
    super.dispose();
  }
}
