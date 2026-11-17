import '../l10n/app_i18n.dart';
import 'package:csslib/parser.dart' as css_parser;
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:html/parser.dart' as html;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../rendering/html_form_submission.dart';
import '../rendering/html_document_urls.dart';
import '../rendering/html_syntax.dart';
import '../rendering/html_document_styles.dart';
import '../rendering/native_html.dart';
import '../rendering/document_absolute_position.dart';
import '../rendering/document_layout.dart';
import '../rendering/document_fragment.dart';
import '../rendering/document_reveal.dart';
import '../rendering/document_scroll_anchor.dart';
import '../rendering/document_touch_boundary.dart';
import '../rendering/document_computed_styles.dart';
import '../rendering/document_offsets.dart';
import '../rendering/document_margin_collapse.dart';
import '../rendering/document_layout_visibility.dart';
import '../rendering/document_element_scroll.dart';
import '../rendering/document_scroll_commands.dart';
import 'common.dart';
import 'gateway.dart';
import 'document_navigation_state.dart';
import 'remote_content_gate.dart';
import 'document_scripts.dart';
import 'document_environment.dart';
import 'document_object_urls.dart';
import 'document_download.dart';
import 'document_referrer.dart';
import 'document_origin.dart';
import 'document_window_manager.dart';
import 'markdown_image.dart';
import 'web_controls.dart';

/// A chooser belongs to its live document/account, including a temporary view
/// removal. Switching windows or replacing/retiring the response ends that lease.
bool Function() _scriptPickerScope(
  NativeFetchedDocument document,
  NativeDocumentScope? scope,
) {
  final windows = scope?.windows;
  final window = scope?.window;
  final identity = scope?.accountIdentity;
  final selection = windows?.selectionRevision;
  return () =>
      !document.liveControls.isDisposed &&
      (windows == null ||
          !windows.disposed &&
              identity == windows.accountIdentity &&
              selection == windows.selectionRevision &&
              window?.disposed != true &&
              window?.closing != true &&
              (window == null ||
                  identical(window.currentDocument, document) &&
                      identical(windows.active, window)));
}

/// Saves supported HTML download links without replacing their source page.
/// Returns false when browser download-attribute rules require ordinary navigation.
Future<bool> saveNativeDocumentLink(
  BuildContext context,
  Gateway gateway,
  NativeHtmlLink link, {
  NativeDocumentScope? scope,
  NativeDocumentBlob? activatedBlob,
}) async {
  if (link.download == null) return false;
  final scheme = Uri.tryParse(link.href)?.scheme.toLowerCase() ?? '';
  if (scheme.isNotEmpty &&
      !['http', 'https', 'data', 'blob'].contains(scheme)) {
    return false;
  }
  final windows = scope?.windows;
  final identity = scope?.accountIdentity;
  final document = scope?.window?.current?.document;
  bool current() =>
      context.mounted &&
      (scope == null ||
          !scope.windows.disposed &&
              identity == scope.windows.accountIdentity &&
              scope.window?.disposed != true &&
              scope.window?.closing != true &&
              (scope.window == null ||
                  scope.window!.current?.document == document));
  if (!current()) return true;
  final boot = windows == null
      ? obj(await gateway.call('boot'))
      : await windows.connection();
  if (!current()) return true;
  final source = scope?.documentUrl ?? '${boot['origin']}/';
  final base = document?.effectiveBase ?? source;
  final data = scheme == 'data';
  final blob = scheme == 'blob';
  final url = data || blob
      ? link.href
      : resolveNativeDocumentUrl(link.href, base);
  final destination = Uri.parse(url),
      origin = Uri.parse(
        source.startsWith('blob:') ? source.substring(5) : source,
      );
  if (!data &&
      !blob &&
      (destination.scheme != origin.scheme ||
          destination.host != origin.host ||
          destination.port != origin.port)) {
    return false;
  }
  final NativeDocumentDownload download;
  if (blob) {
    final scripts = document?.scripts;
    if (scripts == null) {
      throw StateError(tr("Object URL document is unavailable."));
    }
    final contents =
        activatedBlob ??
        NativeDocumentBlob.fromBridge(url, await scripts.readObjectURL(url));
    if (contents.url != url.split('#').first) {
      throw FormatException(tr("Captured Blob URL changed."));
    }
    if (!current()) return true;
    download = NativeDocumentDownload(
      bytes: contents.bytes,
      name: documentDownloadName(url, const {}, hint: link.download),
      mimeType: contents.mimeType.isEmpty
          ? 'application/octet-stream'
          : contents.mimeType,
    );
  } else if (data) {
    download = NativeDocumentDownload.dataUri(url, hint: link.download);
  } else {
    final args = <String, dynamic>{
      'url': url,
      'baseUrl': base,
      'method': 'GET',
      'pairingStamp': boot['pairingStamp'],
      'originUrl': nativeDocumentOrigin(
        scope?.window?.current?.url ?? scope?.documentUrl ?? '',
      ),
      ...nativeDocumentReferrer(
        document,
        url: scope?.window?.current?.url ?? scope?.documentUrl ?? '',
        elementPolicy: link.referrerPolicy,
        noreferrer: link.noreferrer,
      ).requestArguments,
    };
    final response = windows == null
        ? obj(await gateway.call('document', args))
        : await windows.responses.load(args, isCurrent: current);
    if (!current()) return true;
    if ((response['status'] as num) >= 400) throw StateError(tr("下載失敗，請重試。"));
    download = NativeDocumentDownload.response(response, hint: link.download);
  }
  if (current()) await download.save(gateway, '${boot['pairingStamp']}');
  return true;
}

/// Starts the real navigation while its source remains interactive. A 204/205
/// response never replaces that source. The response viewer uses Flutter only.
Future<void> openNativeDocument(
  BuildContext context,
  NativeDocumentScope scope,
  NativeHtmlFormRequest request, {
  ValueChanged<NativeDocumentWindow>? onStarted,
}) async {
  final windows = scope.windows;
  final identity = scope.accountIdentity;
  final selection = windows.selectionRevision;
  final appNavigation =
      scope.window?.appNavigation ?? windows.appNavigationIdentity?.call();
  if (identity != windows.accountIdentity || scope.window?.disposed == true) {
    return;
  }
  if (scope.window == null && windows.active == null) {
    windows.captureSourceAppState();
  }
  final sourceUrl = scope.window?.current?.url ?? scope.documentUrl;
  if (sourceUrl == null) throw StateError(tr("Document URL is unavailable."));
  final window = windows.target(
    request.target,
    scope.window,
    sourceUrl: sourceUrl,
  );
  if (scope.window == null || window.currentAppRoute != null) {
    window.captureCurrentAppState();
  }
  final host = NativeDocumentHost.maybeOf(context);
  final loaded = window.load(
    request,
    baseUrl: scope.window?.current?.document?.effectiveBase ?? sourceUrl,
    origin: nativeDocumentOrigin(sourceUrl),
    referrer: nativeDocumentReferrer(
      scope.window?.currentDocument,
      url: sourceUrl,
    ),
    blobSource: scope.window?.currentDocument == null
        ? null
        : windows.blobSourceFor(
            scope.window!.currentDocument!,
            url: request.url,
          ),
  );
  onStarted?.call(window);
  final result = await loaded;
  if (!context.mounted ||
      identity != windows.accountIdentity ||
      result == NativeDocumentLoadResult.stale ||
      window.disposed) {
    return;
  }
  if (result == NativeDocumentLoadResult.retained) {
    if (window.history.isEmpty) windows.close(window);
    return;
  }
  if (result == NativeDocumentLoadResult.appRoute) {
    final route = window.pendingAppRoute;
    if (route != null &&
        (host != null || !windows.presented) &&
        (scope.window?.appNavigation ??
                windows.appNavigationIdentity?.call()) ==
            appNavigation) {
      if (host != null) {
        await host.showApp(window, expectedSelectionRevision: selection);
      } else if (windows.selectionRevision == selection) {
        window.pendingAppRoute = null;
        await windows.onAppRoute?.call(route);
      }
    }
    return;
  }
  if (!windows.select(window, expectedSelectionRevision: selection)) return;
  if (host != null) return;
  if (!windows.presented) {
    windows.presented = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => NativeDocumentWorkspace(windows: windows),
          settings: const RouteSettings(name: 'native-document'),
        ),
      );
    } finally {
      windows.presented = false;
    }
  }
}

/// Keeps response widgets mounted across App/document history traversal.
/// The live App remains a sibling; offstage documents cannot receive focus,
/// pointer input or active tickers. Account invalidation removes their trees.
class NativeDocumentHost extends StatefulWidget {
  const NativeDocumentHost({
    super.key,
    required this.windows,
    required this.child,
  });
  final NativeDocumentWindows windows;
  final Widget child;
  static NativeDocumentHostState? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_NativeDocumentHostScope>()
      ?.state;
  @override
  NativeDocumentHostState createState() => NativeDocumentHostState();
}

class _NativeDocumentHostScope extends InheritedWidget {
  const _NativeDocumentHostScope({required this.state, required super.child});
  final NativeDocumentHostState state;
  @override
  bool updateShouldNotify(_NativeDocumentHostScope oldWidget) =>
      state != oldWidget.state;
}

class NativeDocumentBackIntent extends Intent {
  const NativeDocumentBackIntent();
}

class NativeDocumentForwardIntent extends Intent {
  const NativeDocumentForwardIntent();
}

class NativeDocumentHostState extends State<NativeDocumentHost> {
  bool _showing = false;
  Future<void> _lifecycle = Future.value();
  int _restoration = 0;
  final _historyFocus = FocusNode(debugLabel: "document-history");
  FocusNode? _sourceFocus;
  NativeDocumentWindows get windows => widget.windows;
  bool get _canHandleBack {
    final active = windows.active;
    if (active?.currentDocument == null &&
        active?.error == null &&
        ((active?.appCanPop ?? windows.appCanPop)?.call() ?? false)) {
      return false;
    }
    return active != null &&
        (active.canBack ||
            active.independentApp && active.currentAppRoute != null ||
            active.currentDocument != null ||
            active.error != null);
  }

  @override
  void initState() {
    super.initState();
    windows.managedPresentation = true;
    windows.addListener(_changed);
  }

  void _changed() {
    if (!mounted || windows.disposed) return;
    final active = windows.active;
    final next =
        active?.currentDocument != null ||
        active?.error != null ||
        (active?.independentApp == true && active?.currentAppRoute != null);
    if (next != _showing) {
      if (next) {
        _sourceFocus = FocusManager.instance.primaryFocus;
      }
      _showing = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _showing != next) return;
        // Requesting an offscreen document editor would scroll its caret into
        // view and overwrite the history offset. Keep keyboard navigation on
        // the host until the user focuses a document control again.
        final focus = next ? null : _sourceFocus;
        if (focus?.context != null && focus!.canRequestFocus) {
          focus.requestFocus();
        } else {
          _historyFocus.requestFocus();
        }
      });
      windows.presented = next;
      final account = windows.accountIdentity;
      _lifecycle = _lifecycle.catchError((Object _) {}).then((_) async {
        if (!mounted ||
            windows.disposed ||
            windows.accountIdentity != account) {
          return;
        }
        if (next) {
          await windows.owner?.coverDocument();
        } else {
          await windows.owner?.uncoverDocument();
        }
      });
    }
    setState(() {});
  }

  Future<void> selectWindow(NativeDocumentWindow? window) async {
    if (windows.disposed ||
        window?.closing == true ||
        window?.disposed == true ||
        window != null && !windows.windows.contains(window)) {
      return;
    }
    final previous = windows.active;
    if (previous == null) windows.captureSourceAppState();
    if (previous?.currentDocument == null) previous?.captureCurrentAppState();
    if (window == null) {
      _restoration++;
      windows.select(null);
      await _lifecycle;
    } else if (window.currentDocument == null && window.error == null) {
      await showApp(window);
    } else {
      _restoration++;
      windows.select(window);
      await _lifecycle;
    }
  }

  Future<void> closeWindow(NativeDocumentWindow window) async {
    if (windows.disposed ||
        window.disposed ||
        window.closing ||
        !windows.windows.contains(window)) {
      return;
    }
    final account = windows.accountIdentity;
    window.setClosing(true);
    try {
      await window.beforeClose?.call();
      if (!mounted ||
          windows.disposed ||
          window.disposed ||
          account != windows.accountIdentity) {
        return;
      }
      final wasActive = windows.active == window;
      windows.close(window);
      if (wasActive) {
        _restoration++;
        final returning = windows.active;
        if (returning != null &&
            returning.currentDocument == null &&
            returning.error == null) {
          await showApp(returning);
        } else {
          await _lifecycle;
        }
      }
    } finally {
      if (!window.disposed && !windows.disposed) {
        window.setClosing(false);
      }
    }
  }

  Future<void> showApp(
    NativeDocumentWindow window, {
    int? expectedSelectionRevision,
  }) async {
    if (!windows.select(
      window,
      expectedSelectionRevision: expectedSelectionRevision,
    )) {
      return;
    }
    final ticket = ++_restoration;
    final account = windows.accountIdentity;
    final generation = window.navigationGeneration;
    final entry = window.current;
    final selection = windows.selectionRevision;
    if (window.independentApp) {
      await WidgetsBinding.instance.endOfFrame;
      await window.appReady;
    }
    final navigation = window.appNavigation;
    await _lifecycle;
    bool current() =>
        mounted &&
        !windows.disposed &&
        !window.disposed &&
        ticket == _restoration &&
        windows.active == window &&
        windows.selectionRevision == selection &&
        account == windows.accountIdentity &&
        generation == window.navigationGeneration &&
        window.current == entry;
    if (!current() || window.appNavigation != navigation) {
      return;
    }
    final state =
        entry?.appState ?? (window.index < 0 ? window.sourceState : null);
    window.pendingAppRoute = null;
    final restore = window.restoreAppState ?? windows.restoreAppState;
    if (state != null && restore != null) {
      await restore(state);
    } else if (entry?.appRoute != null) {
      final route = window.onAppRoute ?? windows.onAppRoute;
      await route?.call(entry!.appRoute!);
    }
    if (current()) window.captureCurrentAppState();
  }

  Future<void> back() async {
    final window = windows.active;
    if (window == null || window.closing) return;
    final scripts = window.currentDocument?.scripts;
    if (scripts?.hasModalDialog == true) {
      await scripts!.requestModalClose();
      return;
    }
    if (!window.canBack) {
      if (window.canReturnToSource &&
          window.index < 0 &&
          window.error != null) {
        window.dismissFailureToSource();
      } else if (window.currentDocument != null || window.independentApp) {
        await closeWindow(window);
      }
      return;
    }
    if (window.currentDocument == null) window.captureCurrentAppState();
    _restoration++;
    final selection = windows.selectionRevision;
    final result = await window.traverseHistory(window.historyCursor - 1);
    if (result != NativeDocumentLoadResult.stale &&
        windows.active == window &&
        windows.selectionRevision == selection &&
        window.currentDocument == null) {
      await showApp(window);
    }
  }

  Future<void> forward() async {
    final window = windows.active;
    if (window == null || window.closing || !window.canForward) return;
    if (window.currentDocument == null) window.captureCurrentAppState();
    _restoration++;
    final selection = windows.selectionRevision;
    final result = await window.traverseHistory(window.historyCursor + 1);
    if (result != NativeDocumentLoadResult.stale &&
        windows.active == window &&
        windows.selectionRevision == selection &&
        window.currentDocument == null) {
      await showApp(window);
    }
  }

  @override
  void dispose() {
    _restoration++;
    windows.removeListener(_changed);
    windows.managedPresentation = false;
    if (_showing && !windows.disposed) {
      unawaited(windows.owner?.uncoverDocument() ?? Future.value());
    }
    windows.presented = false;
    _historyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final ownsBack = _canHandleBack;
    return _NativeDocumentHostScope(
      state: this,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              NativeDocumentBackIntent(),
          SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
              NativeDocumentForwardIntent(),
        },
        child: Actions(
          actions: {
            NativeDocumentBackIntent: CallbackAction<NativeDocumentBackIntent>(
              onInvoke: (_) {
                unawaited(back());
                return null;
              },
            ),
            NativeDocumentForwardIntent:
                CallbackAction<NativeDocumentForwardIntent>(
                  onInvoke: (_) {
                    unawaited(forward());
                    return null;
                  },
                ),
          },
          child: Focus(
            focusNode: _historyFocus,
            autofocus: true,
            child: PopScope(
              canPop: !ownsBack,
              onPopInvokedWithResult: (popped, _) {
                if (!popped && ownsBack) unawaited(back());
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: _showing,
                    child: ExcludeFocus(
                      excluding: _showing || windows.active?.closing == true,
                      child: TickerMode(
                        enabled: !_showing,
                        child: AbsorbPointer(
                          absorbing: windows.active?.closing == true,
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                  Offstage(
                    offstage: !_showing,
                    child: ExcludeFocus(
                      excluding: !_showing,
                      child: TickerMode(
                        enabled: _showing,
                        child: NativeDocumentWorkspace(
                          windows: windows,
                          managed: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NativeDocumentWorkspace extends StatefulWidget {
  const NativeDocumentWorkspace({
    super.key,
    required this.windows,
    this.managed = false,
  });
  final NativeDocumentWindows windows;
  final bool managed;
  @override
  State<NativeDocumentWorkspace> createState() =>
      _NativeDocumentWorkspaceState();
}

class _NativeDocumentWorkspaceState extends State<NativeDocumentWorkspace> {
  final Map<(int, int), Widget> _views = {};
  final Map<int, Widget> _appViews = {};
  Future<void>? _uncover;
  bool _returningToApp = false;
  final _fragmentWaits = <VoidCallback>{};

  @override
  void didUpdateWidget(covariant NativeDocumentWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.windows, widget.windows)) {
      for (final cancel in List<VoidCallback>.of(_fragmentWaits)) {
        cancel();
      }
    }
  }

  Future<void> _uncoverSource() =>
      _uncover ??= widget.windows.owner?.uncoverDocument() ?? Future.value();

  Future<void> _returnToApp(NativeDocumentWindow window) async {
    final windows = widget.windows;
    final route = window.pendingAppRoute;
    if (_returningToApp || route == null || !mounted) return;
    if (widget.managed) {
      await NativeDocumentHost.maybeOf(context)?.showApp(window);
      return;
    }
    _returningToApp = true;
    final identity = windows.accountIdentity;
    final handler = windows.onAppRoute;
    final appNavigation = windows.appNavigationIdentity?.call();
    window.pendingAppRoute = null;
    final generation = window.navigationGeneration;
    Navigator.of(context).pop();
    // Restore the controller lifecycle before selecting a session; otherwise
    // a delayed uncover could rewatch the session we have just replaced.
    await _uncoverSource();
    if (windows.disposed ||
        windows.accountIdentity != identity ||
        window.disposed ||
        window.navigationGeneration != generation ||
        windows.appNavigationIdentity?.call() != appNavigation) {
      return;
    }
    await handler?.call(route);
  }

  @override
  void initState() {
    super.initState();
    if (!widget.managed) {
      unawaited(widget.windows.owner?.coverDocument() ?? Future.value());
    }
  }

  @override
  void dispose() {
    for (final cancel in List<VoidCallback>.of(_fragmentWaits)) {
      cancel();
    }
    final window = widget.windows.active;
    window?.rememberCurrentDocumentState();
    if (!widget.managed &&
        !_returningToApp &&
        window?.canReturnToSource == true) {
      window!.returnToSource();
    }
    if (!widget.managed) unawaited(_uncoverSource());
    super.dispose();
  }

  Future<void> _back() async {
    if (widget.managed) {
      unawaited(NativeDocumentHost.maybeOf(context)?.back() ?? Future.value());
      return;
    }
    final window = widget.windows.active;
    final scripts = window?.currentDocument?.scripts;
    if (scripts?.hasModalDialog == true) {
      await scripts!.requestModalClose();
      return;
    }
    if (window?.canBack == true) {
      final revision = widget.windows.selectionRevision;
      final result = await window!.traverseHistory(window.index - 1);
      if (!mounted ||
          window.disposed ||
          widget.windows.active != window ||
          widget.windows.selectionRevision != revision ||
          result == NativeDocumentLoadResult.stale) {
        return;
      }
      if (window.currentAppRoute != null) {
        unawaited(_returnToApp(window));
      } else if (window.index < 0) {
        Navigator.of(context).pop();
      }
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _forward() async {
    if (widget.managed) {
      unawaited(
        NativeDocumentHost.maybeOf(context)?.forward() ?? Future.value(),
      );
      return;
    }
    final window = widget.windows.active;
    if (window == null) return;
    final revision = widget.windows.selectionRevision;
    final result = await window.traverseHistory(window.historyCursor + 1);
    if (!mounted ||
        window.disposed ||
        widget.windows.active != window ||
        widget.windows.selectionRevision != revision ||
        result == NativeDocumentLoadResult.stale) {
      return;
    }
    if (window.currentAppRoute != null) unawaited(_returnToApp(window));
  }

  Future<void> _closeWindow() async {
    final windows = widget.windows;
    final window = windows.active;
    if (widget.managed && window != null) {
      await NativeDocumentHost.maybeOf(context)?.closeWindow(window);
      return;
    }
    if (window != null) {
      await window.beforeClose?.call();
      if (!mounted || windows.disposed || window.disposed) return;
      windows.close(window);
    }
    if (!widget.managed && windows.windows.isEmpty) Navigator.of(context).pop();
  }

  Future<void> _retry(NativeDocumentWindow window) async {
    final selection = widget.windows.selectionRevision;
    final result = await window.retryRead();
    if (mounted &&
        !window.disposed &&
        widget.windows.selectionRevision == selection &&
        result == NativeDocumentLoadResult.appRoute) {
      await _returnToApp(window);
    }
  }

  Future<void> _reload(
    NativeDocumentWindow window, {
    bool scripted = false,
  }) async {
    if (window.loading && !scripted) {
      window.stop();
      return;
    }
    if (window.disposed || window.closing) return;

    final windows = widget.windows;
    final account = windows.accountIdentity;
    final current = window.current;
    final document = current?.document;
    final currentUrl = current?.url ?? window.sourceUrl;
    final savedRequest = document?.reloadRequest;
    final request = savedRequest?.method.toUpperCase() == 'POST'
        ? NativeHtmlFormRequest(
            url: currentUrl,
            method: 'POST',
            body: savedRequest!.body,
            bodyBytes: savedRequest.bodyBytes,
            contentType: savedRequest.contentType,
            target: '',
          )
        : NativeHtmlFormRequest(url: currentUrl, method: 'GET', target: '');

    if (request.method.toUpperCase() == 'POST') {
      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => WebDialog(
              title: tr("重新送出表單？"),
              actions: [
                WebButton(
                  tr("取消"),
                  onPressed: () => Navigator.pop(dialogContext, false),
                ),
                WebButton(
                  tr("重新送出"),
                  primary: true,
                  onPressed: () => Navigator.pop(dialogContext, true),
                ),
              ],
              children: [Text(tr("重新載入會再次送出這份表單。"))],
            ),
          ) ??
          false;
      if (!confirmed ||
          !mounted ||
          windows.disposed ||
          windows.accountIdentity != account ||
          windows.active != window ||
          window.disposed ||
          window.current != current ||
          window.current?.document != document) {
        return;
      }
    }

    final selection = windows.selectionRevision;
    final result = await window.load(
      request,
      baseUrl: request.url.isEmpty ? currentUrl : request.url,
      blobSource: document?.blobSource,
      revalidate: true,
      replaceCurrent: true,
      origin: document?.navigationOrigin ?? 'null',
      referrer:
          document?.navigationReferrer ??
          const NativeDocumentReferrer('', 'no-referrer'),
    );
    if (mounted &&
        !window.disposed &&
        widget.windows.selectionRevision == selection &&
        result == NativeDocumentLoadResult.appRoute) {
      await _returnToApp(window);
    }
  }

  Future<void> _link(
    NativeDocumentWindow window,
    NativeFetchedDocument document,
    NativeHtmlLink link, {
    bool replaceCurrent = false,
    bool allowFragmentRemoval = false,
    NativeDocumentBlob? activatedBlob,
  }) async {
    if (window.disposed ||
        window.closing ||
        window.historyPostResubmissionRequired ||
        window.current?.document != document) {
      return;
    }
    var saved = false;
    var downloadFailed = false;
    await guarded(context, () async {
      try {
        saved = await saveNativeDocumentLink(
          context,
          widget.windows.gateway,
          link,
          activatedBlob: activatedBlob,
          scope: NativeDocumentScope(
            windows: widget.windows,
            documentUrl: document.url,
            window: window,
            child: const SizedBox(),
          ),
        );
      } catch (_) {
        downloadFailed = true;
        rethrow;
      }
    });
    if (saved ||
        downloadFailed ||
        !mounted ||
        window.disposed ||
        window.closing ||
        window.current?.document != document) {
      return;
    }
    final scheme = Uri.tryParse(link.href)?.scheme.toLowerCase();
    if (scheme == 'mailto') {
      await guarded(
        context,
        () => widget.windows.gateway
            .call('external', {'url': link.href})
            .then((_) {}),
      );
      return;
    }
    final target = link.targetSpecified || link.target.isNotEmpty
        ? link.target
        : document.content.baseTarget ?? '';
    final selection = widget.windows.selectionRevision;
    final selected = widget.windows.target(
      target,
      window,
      sourceUrl: window.current!.url,
      noopener: link.noreferrer ? true : link.noopener,
    );
    final result = await selected.load(
      NativeHtmlFormRequest(url: link.href, method: 'GET', target: target),
      baseUrl: document.effectiveBase,
      origin: nativeDocumentOrigin(window.current!.url),
      referrer: nativeDocumentReferrer(
        document,
        url: window.current!.url,
        elementPolicy: link.referrerPolicy,
        noreferrer: link.noreferrer,
      ),
      blobSource: widget.windows.blobSourceFor(
        document,
        url: link.href,
        referrerPolicy: link.referrerPolicy,
        noreferrer: link.noreferrer,
        initialBlob: activatedBlob,
      ),
      fragmentAllowed: true,
      replaceCurrent: replaceCurrent,
      allowFragmentRemoval: allowFragmentRemoval,
    );
    if (!mounted ||
        selected.disposed ||
        result == NativeDocumentLoadResult.stale) {
      return;
    }
    if (result == NativeDocumentLoadResult.appRoute) {
      if (widget.windows.selectionRevision == selection) {
        await _returnToApp(selected);
      }
      return;
    }
    if (result == NativeDocumentLoadResult.retained &&
        selected.history.isEmpty) {
      widget.windows.close(selected);
    } else {
      widget.windows.select(selected, expectedSelectionRevision: selection);
    }
  }

  Future<void> _scriptNavigate(
    NativeDocumentWindow window,
    NativeFetchedDocument document,
    Json action,
  ) async {
    if (!mounted ||
        widget.windows.active != window ||
        window.disposed ||
        window.closing ||
        window.historyPostResubmissionRequired ||
        window.currentDocument != document) {
      return;
    }
    if (action['kind'] == 'history') {
      await guarded(context, () async {
        final method = action['method'] as String;
        if (method == 'go') {
          final delta = action['delta'] as int;
          if (delta == 0) {
            await _reload(window, scripted: true);
          } else {
            final selection = widget.windows.selectionRevision;
            final result = await window.traverseHistory(
              (action['index'] as int) - (window.canReturnToSource ? 1 : 0),
            );
            if (!mounted ||
                window.disposed ||
                widget.windows.active != window ||
                widget.windows.selectionRevision != selection ||
                result == NativeDocumentLoadResult.stale) {
              return;
            }
            if (window.currentDocument == null) {
              if (widget.managed) {
                await NativeDocumentHost.maybeOf(context)?.showApp(window);
              } else if (window.currentAppRoute != null) {
                await _returnToApp(window);
              } else if (window.index < 0) {
                Navigator.of(context).pop();
              }
            }
          }
        } else if (method == 'scroll') {
          window.setHistoryScrollRestoration(
            document,
            action['scrollRestoration'] as String,
            action['revision'] as int,
          );
        } else {
          window.applyHistoryApiMutation(
            document: document,
            method: method,
            revision: action['revision'] as int,
            url: action['url'] as String,
            stateGraph: obj(action['stateGraph']),
            entryKey: action['entryKey'] as String,
            scrollRestoration: action['scrollRestoration'] as String,
            initialScrollSnapshotPending:
                action['initialScrollSnapshotPending'] as bool?,
            sourceScrollTop: (action['sourceScrollTop'] as num?)?.toDouble(),
          );
        }
      });
    } else if (action['kind'] == 'reload') {
      await _reload(window, scripted: true);
    } else {
      await _link(
        window,
        document,
        NativeHtmlLink(
          action['url'] as String,
          target: action['target'] as String,
          targetSpecified: true,
          download: action['kind'] == 'anchor'
              ? action['download'] as String?
              : null,
          referrerPolicy: action['referrerPolicy'] as String?,
          noreferrer: action['noreferrer'] == true,
          noopener: action['noopener'] as bool?,
        ),
        activatedBlob: action['capturedBlob'] is Map
            ? NativeDocumentBlob.fromBridge(
                action['url'] as String,
                obj(action['capturedBlob']),
              )
            : null,
        replaceCurrent: action['replace'] == true,
        allowFragmentRemoval: action['sameDocument'] == true,
      );
    }
  }

  Future<void> _submit(
    NativeDocumentWindow window,
    NativeFetchedDocument document,
    NativeHtmlFormSubmission submission,
  ) async {
    if (window.disposed ||
        window.closing ||
        window.historyPostResubmissionRequired ||
        window.current?.document != document) {
      return;
    }
    final request = submission.buildRequest(documentUrl: window.current!.url);
    final target = request.targetSpecified || request.target.isNotEmpty
        ? request.target
        : document.content.baseTarget ?? '';
    final selection = widget.windows.selectionRevision;
    final selected = widget.windows.target(
      target,
      window,
      sourceUrl: window.current!.url,
      noopener: request.noopener,
    );
    final result = await selected.load(
      request,
      baseUrl: document.effectiveBase,
      origin: nativeDocumentOrigin(window.current!.url),
      referrer: nativeDocumentReferrer(document, url: window.current!.url),
      blobSource: widget.windows.blobSourceFor(document, url: request.url),
    );
    if (!mounted ||
        selected.disposed ||
        result == NativeDocumentLoadResult.stale) {
      return;
    }
    if (result == NativeDocumentLoadResult.appRoute) {
      if (widget.windows.selectionRevision == selection) {
        await _returnToApp(selected);
      }
      return;
    }
    if (result == NativeDocumentLoadResult.retained &&
        selected.history.isEmpty) {
      widget.windows.close(selected);
    } else {
      widget.windows.select(selected, expectedSelectionRevision: selection);
    }
  }

  /// Wait for the parser/deferred scripts which own initial target selection.
  /// This is event driven: external I/O does not consume the layout retry budget.
  Future<bool> _waitForInitialFragmentDocument(
    NativeDocumentWindow window,
    NativeFetchedDocument document,
    bool Function() isCurrent,
  ) async {
    final scripts = document.scripts;
    if (scripts == null) return isCurrent();
    final windows = widget.windows;
    final done = Completer<bool>();
    void cancel() {
      if (!done.isCompleted) done.complete(false);
    }

    void wake() {
      if (done.isCompleted) return;
      if (!mounted || !identical(widget.windows, windows) || !isCurrent()) {
        cancel();
        return;
      }
      // The native reveal already waits for current layout publication. A
      // no-op layout refresh need not notify listeners when it becomes idle,
      // so waiting for publication here can strand a history traversal.
      if (!scripts.initialTargetSelectionPending &&
          scripts.navigationActions.isEmpty) {
        done.complete(true);
      }
    }

    _fragmentWaits.add(cancel);
    scripts.addListener(wake);
    window.addListener(wake);
    windows.addListener(wake);
    try {
      wake();
      if (!await done.future) return false;
      // A traversal notification can arrive before the VM applies its target.
      // Await the serialized snapshot directly: idle no-op refreshes need not
      // emit a listener notification.
      await scripts.updateHistory(window.scriptHistorySnapshot);
      return isCurrent();
    } finally {
      _fragmentWaits.remove(cancel);
      scripts.removeListener(wake);
      window.removeListener(wake);
      windows.removeListener(wake);
    }
  }

  NativeDocumentHistoryItem? _revealed;
  int _revealedFragmentRevision = -1;
  void _revealFragment(NativeDocumentWindow? window) {
    final current = window?.current;
    if (current == null || current.document == null) {
      _revealed = null;
      return;
    }
    final revision = window!.fragmentRevealRevision;
    if (_revealed == current && _revealedFragmentRevision == revision) return;
    _revealed = current;
    _revealedFragmentRevision = revision;
    final explicit = window.hasPendingFragmentReveal;
    final initial = current.document!.initialFragmentRevealPending;
    if (!explicit &&
        !initial &&
        (window.historyChangeKind == 'pushState' ||
            window.historyChangeKind == 'replaceState' ||
            window.historyChangeKind == 'traverse' &&
                current.scrollRestoration == 'manual')) {
      return;
    }
    final storedOffset =
        explicit || current.document!.initialFragmentRevealPending
        ? null
        : current.scrollOffset;
    final hash = current.url.indexOf('#');
    if (storedOffset == null && hash < 0 && !initial) return;
    final revealUrl = current.url;
    final fragment = hash < 0 ? '' : revealUrl.substring(hash + 1);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          window.current != current ||
          current.url != revealUrl ||
          window.fragmentRevealRevision != revision ||
          (explicit && !window.hasPendingFragmentReveal)) {
        return;
      }
      final document = current.document!;
      bool isCurrent() =>
          mounted &&
          !window.disposed &&
          identical(widget.windows.active, window) &&
          window.current == current &&
          current.url == revealUrl &&
          window.fragmentRevealRevision == revision &&
          (!explicit || window.hasPendingFragmentReveal);
      var savedOffset = storedOffset;
      var preserveRootOffset = false;
      NativeDocumentFragmentTarget? retainedTarget;
      if (!explicit &&
          (savedOffset == null || current.scrollOffsetBeforeInitialFragment) &&
          document.content.isHtml) {
        if (!await _waitForInitialFragmentDocument(
          window,
          document,
          isCurrent,
        )) {
          return;
        }
        if (current.scrollOffsetBeforeInitialFragment &&
            hash >= 0 &&
            document.viewport.fragmentTarget(fragment) != null) {
          savedOffset = null;
        }
        final scripts = document.scripts;
        preserveRootOffset =
            initial && scripts?.initialRootScrollOverride == true;
        if (savedOffset == null && scripts?.fragmentTargetReady == true) {
          final id = scripts!.fragmentTargetId;
          final top =
              id == null &&
              hash >= 0 &&
              (fragment.isEmpty ||
                  decodeNativeDocumentFragment(fragment).toLowerCase() ==
                      'top');
          retainedTarget = top
              ? const NativeDocumentFragmentTarget.top()
              : NativeDocumentFragmentTarget.native(id);
        } else if (hash < 0) {
          // No fragment means no initial scrolling; preserve any script scroll.
          retainedTarget = const NativeDocumentFragmentTarget.native(null);
        }
      }
      if (savedOffset != null &&
          window.historyChangeKind == 'traverse' &&
          !document.fragmentTarget.revealHandled &&
          document.content.isHtml) {
        final scripts = document.scripts;
        if (scripts != null) {
          await scripts.updateHistory(window.scriptHistorySnapshot);
        }
        if (!isCurrent()) return;
        if (scripts?.fragmentAncestorsRevealed ??
            document.fragmentTarget.ancestorsRevealed) {
          // Reveal changed the destination layout; traverse to the fragment
          // instead of a reading position from its previously closed layout.
          savedOffset = null;
          retainedTarget = scripts == null
              ? null
              : NativeDocumentFragmentTarget.native(scripts.fragmentTargetId);
        }
      }
      if (!isCurrent()) return;
      if (savedOffset != null) {
        await document.viewport.restoreScrollOffset(
          document.scroll,
          savedOffset,
          isCurrent: isCurrent,
        );
      } else {
        await document.viewport.scrollToFragment(
          fragment,
          allowUnindexedTop: !document.content.isHtml,
          isCurrent: isCurrent,
          retainedTarget: retainedTarget,
          preserveRootOffset: preserveRootOffset,
        );
      }
      if (mounted &&
          identical(widget.windows.active, window) &&
          window.current == current &&
          window.fragmentRevealRevision == revision) {
        document.fragmentTarget.markRevealHandled(
          document.fragmentTarget.revision,
        );
        document.initialFragmentRevealPending = false;
        current.scrollOffsetBeforeInitialFragment = false;
        current.scrollOffset =
            document.scroll.lastKnownOffset ?? current.scrollOffset;
        window.acknowledgeFragmentReveal(current, revision);
        unawaited(
          document.scripts?.updateHistory(window.scriptHistorySnapshot) ??
              Future.value(),
        );
      }
    });
  }

  Widget _body(NativeDocumentWindow window, NativeFetchedDocument document) =>
      _views.putIfAbsent(
        (window.id, document.id),
        () => NativeDocumentScope(
          windows: widget.windows,
          window: window,
          documentUrl: document.url,
          sourceIdentity: widget.windows.accountIdentity,
          child: NativeFetchedDocumentView(
            key: ValueKey((window.id, document.id)),
            document: document,
            gateway: widget.windows.gateway,
            onLink: (link) => unawaited(_link(window, document, link)),
            onSubmit: (s) => unawaited(_submit(window, document, s)),
            onScriptNavigation: (action) =>
                _scriptNavigate(window, document, action),
          ),
        ),
      );
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return ListenableBuilder(
      listenable: widget.windows,
      builder: (context, _) {
        final windows = widget.windows;
        final window = windows.active;
        final current = window?.current;
        final blockedPost = window?.historyPostResubmissionRequired == true;
        _revealFragment(blockedPost ? null : window);
        final liveDocuments = <(int, int)>{
          for (final w in windows.windows)
            for (final entry in w.history)
              if (entry.document != null) (w.id, entry.document!.id),
        };
        _views.removeWhere((key, _) => !liveDocuments.contains(key));
        _appViews.removeWhere(
          (id, _) => !windows.windows.any((w) => w.id == id),
        );
        final documents = <(NativeDocumentWindow, NativeFetchedDocument)>[];
        for (final w in windows.windows) {
          for (final d
              in w.history
                  .map((e) => e.document)
                  .whereType<NativeFetchedDocument>()
                  .toSet()) {
            documents.add((w, d));
          }
        }
        final alive = {for (final item in documents) (item.$1.id, item.$2.id)};
        _views.removeWhere((key, _) => !alive.contains(key));
        final apps = windows.windows
            .where(
              (w) =>
                  w.independentApp && w.history.any((h) => h.appRoute != null),
            )
            .toList();
        _appViews.removeWhere((id, _) => !apps.any((w) => w.id == id));
        final independentVisible =
            window?.independentApp == true && current?.appRoute != null;
        return PopScope(
          canPop:
              widget.managed ||
              (window?.canBack != true && window?.currentDocument == null),
          onPopInvokedWithResult: (popped, _) {
            if (!widget.managed && !popped) _back();
          },
          child: Scaffold(
            appBar: independentVisible
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(48),
                    child: SafeArea(
                      bottom: false,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48),
                        decoration: BoxDecoration(
                          color: palette(context)['surface.page'],
                          border: Border(
                            bottom: BorderSide(
                              color: palette(context)['line.default'],
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            WebIconButton(
                              LucideIcons.chevronLeft,
                              tr("返回"),
                              onPressed: _back,
                            ),
                            WebIconButton(
                              LucideIcons.chevronRight,
                              tr("下一頁"),
                              onPressed: window?.canForward == true
                                  ? _forward
                                  : null,
                            ),
                            WebIconButton(
                              window?.loading == true
                                  ? LucideIcons.x
                                  : LucideIcons.rotateCw,
                              window?.loading == true ? tr("停止") : tr("重新載入"),
                              onPressed: window == null
                                  ? null
                                  : () => unawaited(_reload(window)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Tooltip(
                                message:
                                    current?.url ?? window?.sourceUrl ?? '',
                                child: Text(
                                  current?.document?.content.title
                                              ?.trim()
                                              .isNotEmpty ==
                                          true
                                      ? current!.document!.content.title!
                                      : current?.url ?? tr("網頁內容"),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: webText(context),
                                ),
                              ),
                            ),
                            WebIconButton(
                              LucideIcons.panelsTopLeft,
                              tr("App 視窗"),
                              onPressed: widget.managed
                                  ? () {
                                      final host = NativeDocumentHost.maybeOf(
                                        context,
                                      );
                                      if (host != null) {
                                        showNativeDocumentWindowManager(
                                          context,
                                          windows,
                                          host,
                                        );
                                      }
                                    }
                                  : null,
                            ),
                            WebIconButton(
                              LucideIcons.x,
                              tr("關閉頁面"),
                              onPressed: _closeWindow,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
            body: Column(
              children: [
                if (window?.loading == true)
                  const LinearProgressIndicator(minHeight: 2),
                if (windows.connectionError != null || window?.error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    color: palette(context)['surface.subtle'],
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          windows.connectionError ?? window!.error!,
                          style: webText(context, color: 'status.danger'),
                        ),
                        if (windows.connectionError == null &&
                            window?.mutationOutcomeUnknown == true)
                          Text(tr("送出結果尚未確認，請先檢查伺服器狀態。")),
                        if (windows.connectionError == null &&
                            window?.failedRequest?.method == 'GET')
                          WebButton(
                            tr("重試"),
                            onPressed: () => unawaited(_retry(window!)),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (blockedPost)
                        const _NativeHistoryPostResubmissionPage(),
                      for (final appWindow in apps)
                        Offstage(
                          offstage:
                              appWindow != window || current?.appRoute == null,
                          child: ExcludeFocus(
                            excluding:
                                appWindow != window ||
                                current?.appRoute == null ||
                                appWindow.closing,
                            child: TickerMode(
                              enabled:
                                  appWindow == window &&
                                  current?.appRoute != null,
                              child: AbsorbPointer(
                                absorbing: appWindow.closing,
                                child: _appViews.putIfAbsent(
                                  appWindow.id,
                                  () => windows.appBuilder!(appWindow),
                                ),
                              ),
                            ),
                          ),
                        ),
                      for (final item in documents)
                        Offstage(
                          offstage:
                              item.$1 != window ||
                              item.$2 != current?.document ||
                              blockedPost,
                          child: TickerMode(
                            enabled:
                                item.$1 == window &&
                                item.$2 == current?.document &&
                                !blockedPost,
                            child: ExcludeFocus(
                              excluding:
                                  item.$1 != window ||
                                  item.$2 != current?.document ||
                                  item.$1.closing ||
                                  blockedPost,
                              child: AbsorbPointer(
                                absorbing: item.$1.closing || blockedPost,
                                child: _body(item.$1, item.$2),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Full response documents use their own default HTML typography and canvas;
/// the source conversation's Markdown theme is not a page stylesheet.
class NativeFetchedDocumentView extends StatefulWidget {
  const NativeFetchedDocumentView({
    super.key,
    required this.document,
    required this.gateway,
    required this.onLink,
    required this.onSubmit,
    this.onScriptNavigation,
  });
  final NativeFetchedDocument document;
  final Gateway gateway;
  final ValueChanged<NativeHtmlLink> onLink;
  final ValueChanged<NativeHtmlFormSubmission> onSubmit;
  final FutureOr<void> Function(Json)? onScriptNavigation;
  @override
  State<NativeFetchedDocumentView> createState() =>
      _NativeFetchedDocumentViewState();
}

class _NativeFetchedDocumentViewState extends State<NativeFetchedDocumentView> {
  Widget? _body;
  NativeDocumentScripts? _scripts;
  NativeDocumentObjectUrlBinding? _objectUrls;
  NativeDocumentScope? _scope;
  NativeDocumentWindow? _window;
  NativeDocumentWindows? _windows;
  bool _tickerVisible = true;
  final _layout = NativeDocumentLayoutController();
  final _scrollAnchors = NativeDocumentScrollAnchorData();
  NativeDocumentElementScrollController get _elementScroll =>
      widget.document.elementScroll;
  Size _layoutViewport = Size.zero;
  final Map<
    int,
    ({
      NativeDocumentScripts scripts,
      String id,
      Offset start,
      Offset viewportOrigin,
      Rect dialogBounds,
      bool primary,
      int button,
      Future<bool> downPrevented,
    })
  >
  _modalBackdropPointers = {};

  Json _modalBackdropEventData(
    PointerEvent event,
    Rect dialogBounds, {
    required Offset point,
    required bool primary,
    required int button,
  }) {
    final touch = event.kind == PointerDeviceKind.touch;
    final pointerType = switch (event.kind) {
      PointerDeviceKind.touch => 'touch',
      PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => 'pen',
      _ => 'mouse',
    };
    final rawButtons = event is PointerUpEvent || event is PointerCancelEvent
        ? 0
        : event.buttons;
    final buttons =
        (rawButtons & kPrimaryMouseButton != 0 ? 1 : 0) |
        (rawButtons & kSecondaryMouseButton != 0 ? 2 : 0) |
        (rawButtons & kMiddleMouseButton != 0 ? 4 : 0);
    return {
      'pointerId': pointerType == 'mouse' ? 1 : event.pointer + 2,
      'pointerType': pointerType,
      'isPrimary': primary,
      'clientX': point.dx,
      'clientY': point.dy,
      'offsetX': point.dx - dialogBounds.left,
      'offsetY': point.dy - dialogBounds.top,
      'button': button,
      'buttons': touch && event is PointerDownEvent && buttons == 0
          ? 1
          : buttons,
      'pressure': event is PointerUpEvent || event is PointerCancelEvent
          ? 0.0
          : event.pressure,
      'geometry': {
        'left': dialogBounds.left,
        'top': dialogBounds.top,
        'width': dialogBounds.width,
        'height': dialogBounds.height,
      },
      'metaKey': HardwareKeyboard.instance.isMetaPressed,
      'ctrlKey': HardwareKeyboard.instance.isControlPressed,
      'shiftKey': HardwareKeyboard.instance.isShiftPressed,
      'altKey': HardwareKeyboard.instance.isAltPressed,
    };
  }

  void _modalBackdropPointer(PointerDownEvent event, Rect dialogBounds) {
    final scripts = _scripts;
    if (scripts == null || !scripts.hasModalDialog) return;
    final button = event.buttons & kSecondaryMouseButton != 0
        ? 2
        : event.buttons & kMiddleMouseButton != 0
        ? 1
        : 0;
    final primary =
        event.kind != PointerDeviceKind.touch ||
        !_modalBackdropPointers.values.any(
          (pointer) => pointer.scripts == scripts && pointer.primary,
        );
    final pointer = (
      scripts: scripts,
      id: scripts.modalDialogIds.last,
      start: event.localPosition,
      viewportOrigin: event.position - event.localPosition,
      dialogBounds: dialogBounds,
      primary: primary,
      button: button,
      downPrevented: scripts.dispatchModalBackdropPointerDown(
        scripts.modalDialogIds.last,
        _modalBackdropEventData(
          event,
          dialogBounds,
          point: event.localPosition,
          primary: primary,
          button: button,
        ),
      ),
    );
    if (_modalBackdropPointers.containsKey(event.pointer)) {
      GestureBinding.instance.pointerRouter.removeRoute(
        event.pointer,
        _modalBackdropRoute,
      );
    }
    _modalBackdropPointers[event.pointer] = pointer;
    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _modalBackdropRoute,
    );
  }

  void _modalBackdropRoute(PointerEvent event) {
    if (event is PointerDownEvent) return;
    final pointer = _modalBackdropPointers[event.pointer];
    if (pointer == null) return;
    if (!mounted || !identical(_scripts, pointer.scripts)) {
      _modalBackdropPointers.remove(event.pointer);
      GestureBinding.instance.pointerRouter.removeRoute(
        event.pointer,
        _modalBackdropRoute,
      );
      return;
    }
    final point = event.position - pointer.viewportOrigin;
    final data = _modalBackdropEventData(
      event,
      pointer.dialogBounds,
      point: point,
      primary: pointer.primary,
      button: pointer.button,
    );
    if (event is PointerMoveEvent) {
      unawaited(
        pointer.scripts.dispatchDetailed(pointer.id, 'pointermove', [], data),
      );
    } else if (event is PointerUpEvent) {
      _modalBackdropPointers.remove(event.pointer);
      GestureBinding.instance.pointerRouter.removeRoute(
        event.pointer,
        _modalBackdropRoute,
      );
      unawaited(() async {
        await pointer.scripts.dispatchDetailed(
          pointer.id,
          'pointerup',
          [],
          data,
        );
        final downPrevented = await pointer.downPrevented;
        if (!mounted ||
            !identical(_scripts, pointer.scripts) ||
            pointer.button != 0 ||
            (point - pointer.start).distance > 18) {
          return;
        }
        if (event.kind != PointerDeviceKind.touch) {
          await pointer.scripts.dispatchDetailed(pointer.id, 'click', [], data);
          return;
        }
        String? targetId = pointer.scripts.modalDialogIds.lastOrNull;
        if (targetId == null) {
          // Wait for the layout produced by closing the final dialog before
          // choosing the newly exposed target. A blank hit resolves to <html>
          // in the script runtime; a real control retains its measured ID.
          for (var frame = 0; frame < 3; frame++) {
            if (!mounted || !identical(_scripts, pointer.scripts)) return;
            final hit = _layout.hitTestDocument(
              event.position,
              revision: pointer.scripts.layoutRevision,
            );
            if (hit != null) {
              targetId = hit.elementId;
              break;
            }
            await WidgetsBinding.instance.endOfFrame;
          }
        }
        if (!mounted || !identical(_scripts, pointer.scripts)) return;
        await pointer.scripts.dispatchModalBackdropTouchCompatibility(
          targetId,
          {...data, 'suppressCompatibilityMouse': downPrevented},
        );
      }());
    } else if (event is PointerCancelEvent) {
      _modalBackdropPointers.remove(event.pointer);
      GestureBinding.instance.pointerRouter.removeRoute(
        event.pointer,
        _modalBackdropRoute,
      );
      unawaited(
        pointer.scripts.dispatchDetailed(pointer.id, 'pointercancel', [], data),
      );
    }
  }

  late final _touchBoundary = NativeDocumentTouchBoundary(
    onExit: (id, relatedTarget, position) {
      final scripts = _scripts;
      if (scripts == null ||
          !scripts.ready ||
          !scripts.canvases.containsKey(id)) {
        return;
      }
      unawaited(
        scripts.dispatchDetailed(id, 'mouseout', [], {
          'clientX': position.dx,
          'clientY': position.dy,
          'relatedTarget': relatedTarget,
        }),
      );
    },
  );

  ({
    PointerUpEvent event,
    NativeDocumentScripts scripts,
    int sequence,
    int epoch,
  })?
  _pendingTouchHit;

  void _clearTouchBoundary() {
    _pendingTouchHit = null;
    _touchBoundary.clear();
    for (final pointer in _modalBackdropPointers.keys) {
      GestureBinding.instance.pointerRouter.removeRoute(
        pointer,
        _modalBackdropRoute,
      );
    }
    _modalBackdropPointers.clear();
  }

  void _documentTouchUp(PointerUpEvent event) {
    if (!_touchBoundary.up(event)) return;
    final scripts = _scripts;
    if (scripts == null || !scripts.ready) return;
    _pendingTouchHit = (
      event: event,
      scripts: scripts,
      sequence: _touchBoundary.sequence,
      epoch: _touchBoundary.epoch,
    );
    // A late queued click can publish another DOM revision. If its matching
    // frame is not ready, the real layout notification completes this request.
    _completeTouchTarget();
  }

  bool _completeTouchTarget() {
    final pending = _pendingTouchHit;
    if (pending == null) return true;
    if (!mounted ||
        !identical(_scripts, pending.scripts) ||
        !pending.scripts.ready ||
        pending.sequence != _touchBoundary.sequence ||
        pending.epoch != _touchBoundary.epoch) {
      _pendingTouchHit = null;
      return true;
    }
    final hit = _layout.hitTestDocument(
      pending.event.position,
      revision: pending.scripts.layoutRevision,
    );
    if (hit == null) return false;
    _pendingTouchHit = null;
    _touchBoundary.completeTarget(hit.elementId, pending.event.localPosition);
    return true;
  }

  VoidCallback? _nativeTouchClickQueued(String id, Json data) {
    final scripts = _scripts;
    final pointerId = data['pointerId'];
    if (scripts == null ||
        !scripts.ready ||
        pointerId is! int ||
        !scripts.canvases.containsKey(id)) {
      return null;
    }
    final epoch = _touchBoundary.epoch;
    _touchBoundary.queuedClick(id, pointerId);
    return () {
      if (!mounted ||
          !identical(_scripts, scripts) ||
          _touchBoundary.epoch != epoch) {
        return;
      }
      _touchBoundary.finishedClick(id, pointerId);
      _completeTouchTarget();
      _touchBoundary.reconcile();
    };
  }

  Future<bool> _dispatchNativeDetailedEvent(
    String id,
    String type,
    List<Json> controls,
    Json data,
  ) async {
    final scripts = _scripts;
    if (scripts == null) return true;
    final epoch = _touchBoundary.epoch;
    final touchClick =
        type == 'click' &&
        data['pointerType'] == 'touch' &&
        data['isPrimary'] == true &&
        scripts.canvases.containsKey(id);
    if (touchClick) _touchBoundary.acceptedClick(id);
    final result = await scripts.dispatchDetailed(id, type, controls, data);
    if (touchClick &&
        mounted &&
        identical(_scripts, scripts) &&
        _touchBoundary.epoch == epoch) {
      _completeTouchTarget();
      _touchBoundary.reconcile();
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    _elementScroll.beginDocument(widget.document);
    _elementScroll.addListener(_nativeLayoutChanged);
    widget.document.scroll.addListener(_nativeScrollChanged);
    _layout.addListener(_nativeLayoutChanged);
    widget.document.viewport.bindNativeReveal(this, _nativeFragmentReveal);
  }

  void _nativeScrollChanged() => _scripts?.refreshLayout();
  void _nativeLayoutChanged() {
    _scripts?.refreshLayout();
    _completeTouchTarget();
  }

  Future<Json?> _captureLayout(int revision, int generation) async {
    final document = widget.document;
    final scripts = _scripts;
    // The DOM snapshot has already been published by the serialized script
    // host. Wait for its actual Flutter layout, never infer boxes from CSS.
    for (var attempt = 0; attempt < 3; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          !identical(widget.document, document) ||
          !identical(_scripts, scripts) ||
          scripts?.layoutRevision != revision) {
        return null;
      }
      if (!_scrollAnchors.settled ||
          !_elementScroll.anchoringSettled ||
          scripts?.scrollActions.isNotEmpty == true) {
        continue;
      }
      final pendingScrollEvents = _elementScroll.pendingScrollEvents;
      final packet = _layout.capture(
        revision: revision,
        generation: generation,
        viewport: _layoutViewport,
        requestedIds: scripts?.layoutElementIds,
        elementScrollMetrics: _elementScroll.metricsFor,
        elementScrollRanges: _elementScroll.scrollRangeFor,
        elementScrollActivity: _elementScroll.isScrollingFor,
        elementScrollSurfaces: _elementScroll.scrollGeometrySurfaces,

        contentSize:
            document.scroll.hasClients &&
                document.scroll.position.hasContentDimensions
            ? Size(
                _layoutViewport.width,
                document.scroll.position.maxScrollExtent +
                    document.scroll.position.viewportDimension,
              )
            : null,
        scrollOffset: Offset(
          0,
          document.scroll.hasClients ? document.scroll.offset : 0,
        ),
      );
      if (packet != null) {
        packet['scrollActionThrough'] = scripts!.resolvedScrollActionId;
        (packet['viewport'] as Json)['scrollBehavior'] =
            _viewportScrollBehavior;
        (packet['viewport'] as Json)['scrollActive'] =
            document.scroll.hasClients &&
            document.scroll.position.isScrollingNotifier.value;
        if (document.scroll.hasClients &&
            document.scroll.position.hasContentDimensions) {
          (packet['viewport'] as Json)['scrollRange'] = {
            'minLeft': 0,
            'maxLeft': 0,
            'minTop': document.scroll.position.minScrollExtent,
            'maxTop': document.scroll.position.maxScrollExtent,
          };
        }
        final eligible = <Object?>{
          for (final raw in packet['boxes'] as List)
            if (obj(raw)['kind'] == 'box' && obj(raw)['scroll'] is Map)
              obj(raw)['id'],
        };
        final events = <String, Map<String, dynamic>>{};
        for (final event in pendingScrollEvents) {
          if (eligible.contains(event['id'])) {
            events.putIfAbsent(event['id'] as String, () => event);
          }
        }
        if (events.isNotEmpty) packet['scrollEvents'] = events.values.toList();
        if (pendingScrollEvents.isNotEmpty) {
          packet['nativeScrollEventThrough'] =
              pendingScrollEvents.last['sequence'];
        }
        return packet;
      }
    }
    return null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerVisible = TickerMode.valuesOf(context).enabled;
    final scope = NativeDocumentScope.maybeOf(context);
    if (!identical(_scope, scope)) {
      _scope = scope;
      _bindLifecycleListeners(scope);
    }
    if (_scripts == null) _attachScripts();
    _syncScriptActivity();
  }

  void _bindLifecycleListeners(NativeDocumentScope? scope) {
    final window = scope?.window;
    if (!identical(_window, window)) {
      _window?.removeListener(_syncScriptActivity);
      _window = window;
      _window?.addListener(_syncScriptActivity);
    }
    final windows = scope?.windows;
    if (!identical(_windows, windows)) {
      _windows?.removeListener(_syncScriptActivity);
      _windows = windows;
      _windows?.addListener(_syncScriptActivity);
    }
  }

  int _renderedTargetRevision = -1;
  void _syncScriptActivity() {
    if (_scripts == null &&
        widget.document.content.isHtml &&
        mounted &&
        _renderedTargetRevision != widget.document.fragmentTarget.revision) {
      setState(() {});
    }
    final scripts = _scripts;
    if (scripts == null) return;
    final scope = _scope;
    final window = scope?.window;
    final attached =
        scope == null ||
        !scope.windows.disposed &&
            scope.accountIdentity == scope.windows.accountIdentity &&
            window?.disposed != true &&
            window?.closing != true &&
            window?.historyPostResubmissionRequired != true &&
            (window == null ||
                identical(window.currentDocument, widget.document));
    if (!attached || !_tickerVisible) _clearTouchBoundary();
    scripts.setActivity(
      owner: this,
      attached: attached,
      visible: attached && _tickerVisible,
    );
    if (attached && window?.current?.url != null) {
      unawaited(scripts.updateHistory(window!.scriptHistorySnapshot));
    }
  }

  void _attachScripts() {
    final document = widget.document;
    if (document.pairedOrigin ||
        documentIsAttachment(document.headers) ||
        !NativeDocumentScripts.needsRuntime(document.content)) {
      return;
    }
    _scripts = document.scripts ??= NativeDocumentScripts(widget.gateway);
    final scripts = _scripts!;
    scripts.bindLayout(
      this,
      _captureLayout,
      onAccepted: (packet) {
        final through = packet['nativeScrollEventThrough'];
        if (through is int) {
          document.elementScroll.acknowledgeScrollEvents(through);
        }
      },
    );
    scripts.configureStyles(
      encoding: document.content.encoding,
      prepared: document.preparedStyles,
    );
    _objectUrls = NativeDocumentObjectUrlBinding(
      owner: scripts,
      isCurrent: () =>
          mounted &&
          identical(widget.document, document) &&
          identical(_scripts, scripts) &&
          scripts.ready &&
          (_scope == null ||
              !_scope!.windows.disposed &&
                  _scope!.accountIdentity == _scope!.windows.accountIdentity &&
                  _scope!.window?.disposed != true &&
                  _scope!.window?.closing != true &&
                  (_scope!.window == null ||
                      identical(_scope!.window!.currentDocument, document))),
      readBytes: scripts.readObjectURL,
    );
    _scripts!.addListener(_scriptChanged);
    _syncScriptActivity();
    // LayoutBuilder publishes the real document viewport before scripts run.
    // A navigation that leaves this widget before layout must not start a VM.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(widget.document, document) ||
          !identical(_scripts, scripts)) {
        return;
      }
      unawaited(
        _scope?.windows.startDocumentScripts(document, scripts) ??
            scripts.start(
              source: document.content.text,
              url: document.url,
              referrerPolicy:
                  document.headers['referrer-policy'] ??
                  document.inheritedReferrerPolicy,
              blobCreatorUrl: document.blobCreatorUrl,
              referrer: document.referrer,
            ),
      );
    });
  }

  void _scriptChanged() {
    if (mounted) {
      _syncScriptActivity();
      setState(() {});
    }
  }

  String? _fragmentRootId;
  Set<String> _fragmentKnownIds = const {};
  int _fragmentLayoutRevision = 0;
  int _fragmentCaptureGeneration = 0;
  NativeFragmentRevealResult _nativeFragmentReveal(
    String? id,
    NativeFragmentRevealPhase phase,
    bool preserveRootOffset,
  ) {
    final document = widget.document;
    if (!mounted ||
        document.content.isHtml &&
            _scripts == null &&
            _renderedTargetRevision != document.fragmentTarget.revision ||
        !document.scroll.hasClients ||
        !document.scroll.position.hasContentDimensions ||
        _scripts != null &&
            (_scripts?.ready != true ||
                _scripts!.hasPendingPublication ||
                _scripts!.scrollActions.isNotEmpty ||
                _scripts!.focusActions.isNotEmpty ||
                _fragmentLayoutRevision != _scripts!.layoutRevision ||
                !_scripts!.layoutElementIds.contains(_fragmentRootId)) ||
        !_scrollAnchors.settled ||
        !_elementScroll.anchoringSettled) {
      return NativeFragmentRevealResult.unavailable;
    }
    if (id == null) {
      if (phase == NativeFragmentRevealPhase.prepare || preserveRootOffset) {
        return NativeFragmentRevealResult.handled;
      }
      applyNativeDocumentScrollAxis(
        document.scroll,
        0,
        relative: false,
        behavior: 'auto',
        cssBehavior: _viewportScrollBehavior,
      );
      return NativeFragmentRevealResult.handled;
    }
    final rootId = _fragmentRootId;
    if (rootId == null || !_fragmentKnownIds.contains(id)) {
      return NativeFragmentRevealResult.unavailable;
    }
    final surfaces = _elementScroll.scrollGeometrySurfaces;
    final ids = {
      id,
      rootId,
      for (final entry in surfaces.entries)
        if (nativeDocumentRevealScrollport(entry.value) != null &&
            _fragmentKnownIds.contains(entry.key))
          entry.key,
    };
    if (ids.length > NativeDocumentLayoutController.maximumElementCount) {
      return NativeFragmentRevealResult.unsupported;
    }
    final packet = _layout.capture(
      revision: _fragmentLayoutRevision,
      generation: ++_fragmentCaptureGeneration,
      requestedIds: ids,
      viewport: _layoutViewport,
      scrollOffset: Offset(0, document.scroll.offset),
      contentSize: Size(
        _layoutViewport.width,
        document.scroll.position.maxScrollExtent +
            document.scroll.position.viewportDimension,
      ),
      elementScrollMetrics: _elementScroll.metricsFor,
      elementScrollRanges: _elementScroll.scrollRangeFor,
      elementScrollSurfaces: surfaces,
    );
    if (packet == null) return NativeFragmentRevealResult.unavailable;
    (packet['viewport'] as Json)['scrollRange'] = {
      'minLeft': 0,
      'maxLeft': 0,
      'minTop': document.scroll.position.minScrollExtent,
      'maxTop': document.scroll.position.maxScrollExtent,
    };
    if (phase == NativeFragmentRevealPhase.centered) {
      final caret = document.viewport.focusCaret;
      if (caret != null && caret.id == id) {
        final rect = _layout.measureOwnedRect(id, caret.surface, caret.rect);
        if (rect == null) return NativeFragmentRevealResult.unavailable;
        final target =
            (packet['boxes'] as List).where((box) => box['id'] == id).single
                as Map;
        target['focusRect'] = [rect.left, rect.top, rect.width, rect.height];
      }
    }
    try {
      final plan = nativeDocumentRevealPlan(
        packet,
        id,
        rootId,
        centerFocus: phase == NativeFragmentRevealPhase.centered,
      );
      if (phase == NativeFragmentRevealPhase.prepare) {
        return NativeFragmentRevealResult.handled;
      }
      for (final action in plan) {
        if (action.elementId != null) {
          _elementScroll.applyActions([
            {
              'id': action.elementId,
              'op': 'to',
              'left': action.destination.dx,
              'top': action.destination.dy,
              'behavior': 'auto',
            },
          ]);
        } else if (!preserveRootOffset) {
          applyNativeDocumentScrollAxis(
            document.scroll,
            action.destination.dy,
            relative: false,
            behavior: 'auto',
            cssBehavior: _viewportScrollBehavior,
          );
        }
      }
      _scripts?.refreshLayout();
      return NativeFragmentRevealResult.handled;
    } on UnsupportedError {
      return NativeFragmentRevealResult.unsupported;
    }
  }

  String _viewportScrollBehavior = 'auto';
  bool _scrollScheduled = false;
  void _scheduleScroll() {
    final scripts = _scripts;
    if (_scrollScheduled || scripts == null || scripts.scrollActions.isEmpty) {
      return;
    }
    _scrollScheduled = true;
    final document = widget.document;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Anchor compensation runs after document layout. Queue commands after
      // those frame callbacks, so scrollTo wins over a same-turn content shift
      // and scrollBy composes with the compensated position.
      scheduleMicrotask(() {
        _scrollScheduled = false;
        if (!mounted ||
            !identical(widget.document, document) ||
            !identical(_scripts, scripts) ||
            !document.scroll.hasClients ||
            !document.scroll.position.hasContentDimensions) {
          return;
        }
        if (!_scrollAnchors.settled || !_elementScroll.anchoringSettled) {
          _scheduleScroll();
          WidgetsBinding.instance.ensureVisualUpdate();
          return;
        }
        final actions = scripts.takeScrollActions();
        if (actions.isEmpty) return;
        // Preserve order across root and element targets. Each relative command
        // reads actual pixels, never an earlier smooth animation's destination.
        for (final action in actions) {
          if (action['elementId'] is String) {
            if (scripts.layoutElementIds.contains(action['elementId'])) {
              _elementScroll.applyActions([
                {
                  'id': action['elementId'],
                  'op': action['kind'] == 'by' ? 'scrollBy' : 'scrollTo',
                  'left': action['x'],
                  'top': action['y'],
                  'behavior': action['resolvedBehavior'] ?? action['behavior'],
                },
              ]);
            }
          } else {
            applyNativeDocumentScrollAxis(
              document.scroll,
              (action['y'] as num?)?.toDouble(),
              relative: action['kind'] == 'by',
              behavior:
                  (action['resolvedBehavior'] ?? action['behavior']) as String,
              cssBehavior: _viewportScrollBehavior,
            );
          }
        }
        scripts.refreshLayout();
      });
    });
  }

  bool _navigationScheduled = false, _navigationRunning = false;
  void _scheduleNavigation() {
    final scripts = _scripts;
    if (_navigationScheduled ||
        _navigationRunning ||
        scripts == null ||
        widget.onScriptNavigation == null ||
        scripts.navigationActions.isEmpty) {
      return;
    }
    _navigationScheduled = true;
    final document = widget.document;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _navigationScheduled = false;
      if (!mounted || widget.document != document || _scripts != scripts) {
        return;
      }
      _navigationRunning = true;
      try {
        // Consume one current command at a time. A save picker can await the
        // user; newer navigation may supersede pending navigation meanwhile,
        // without deleting an independent download or reviving a stale command.
        while (mounted && widget.document == document && _scripts == scripts) {
          final next =
              scripts.navigationActions
                  .where(
                    (action) =>
                        action['kind'] == 'history' && action['method'] != 'go',
                  )
                  .firstOrNull ??
              scripts.navigationActions.firstOrNull;
          if (next == null) break;
          final actions = scripts.takeNavigationActions([
            next['sequence'] as int,
          ]);
          if (actions.isEmpty) break;
          await widget.onScriptNavigation?.call(actions.single);
        }
      } finally {
        _navigationRunning = false;
        if (mounted) _scheduleNavigation();
      }
    });
  }

  @override
  void didUpdateWidget(covariant NativeFetchedDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      oldWidget.document.viewport.bindNativeReveal(this, null);
      widget.document.viewport.bindNativeReveal(this, _nativeFragmentReveal);
      _fragmentRootId = null;
      _fragmentKnownIds = const {};
      _viewportScrollBehavior = 'auto';
      _clearTouchBoundary();
      _scrollAnchors.nodes = const {};
      oldWidget.document.elementScroll.removeListener(_nativeLayoutChanged);
      _elementScroll.beginDocument(widget.document);
      _elementScroll.addListener(_nativeLayoutChanged);
      oldWidget.document.scroll.removeListener(_nativeScrollChanged);
      widget.document.scroll.addListener(_nativeScrollChanged);
      _scripts?.detachView(
        this,
        preserveFilePicker: _scriptPickerScope(oldWidget.document, _scope)(),
      );
      _scripts?.removeListener(_scriptChanged);
      _scripts = null;
      _objectUrls = null;
      _body = null;
      _attachScripts();
      _syncScriptActivity();
    }
  }

  @override
  void dispose() {
    widget.document.viewport.bindNativeReveal(this, null);
    _clearTouchBoundary();
    widget.document.scroll.removeListener(_nativeScrollChanged);
    _scripts?.detachView(
      this,
      preserveFilePicker: _scriptPickerScope(widget.document, _scope)(),
    );
    _layout.removeListener(_nativeLayoutChanged);
    _layout.dispose();
    _elementScroll.removeListener(_nativeLayoutChanged);
    _scripts?.removeListener(_scriptChanged);
    _window?.removeListener(_syncScriptActivity);
    _windows?.removeListener(_syncScriptActivity);
    super.dispose();
  }

  NativeDocumentEnvironment _displayEnvironment({
    required double width,
    required double height,
    required bool dark,
  }) {
    final media = MediaQuery.of(context);
    final touch = const {
      TargetPlatform.android,
      TargetPlatform.iOS,
    }.contains(Theme.of(context).platform);
    return NativeDocumentEnvironment(
      width: width.isFinite ? width : media.size.width,
      height: height.isFinite ? height : media.size.height,
      screenWidth: media.size.width,
      screenHeight: media.size.height,
      devicePixelRatio: media.devicePixelRatio,
      dark: dark,
      reducedMotion: media.disableAnimations,
      pointer: touch ? 'coarse' : 'fine',
      hover: touch ? 'none' : 'hover',
    );
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    _scheduleNavigation();
    _scheduleScroll();
    final document = widget.document;
    final base = Theme.of(context);
    final pageTheme = base.copyWith(
      brightness: Brightness.light,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.light,
        primary: const Color(0xff005fcc),
      ),
    );
    final page = ColoredBox(
      color: Colors.white,
      child: Theme(
        data: pageTheme,
        child: DefaultTextStyle(
          style: const TextStyle(
            inherit: false,
            color: Colors.black,
            fontFamily: 'serif',
            fontSize: 16,
            height: kTextHeightNone,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final environment = _displayEnvironment(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                dark: base.brightness == Brightness.dark,
              );
              _layoutViewport = Size(environment.width, environment.height);
              final scripts = _scripts;
              if (scripts != null) {
                unawaited(scripts.updateEnvironment(environment));
              }
              return Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _touchBoundary.down,
                onPointerUp: _documentTouchUp,
                onPointerCancel: _touchBoundary.cancel,
                child: NativeDocumentScrollAnchorViewport(
                  controller: document.scroll,
                  layout: _layout,
                  data: _scrollAnchors,
                  elements: _elementScroll,
                  child: NativeDocumentPositioningViewport(
                    scrollChanges: document.scroll,
                    onModalBackdropPointer: _modalBackdropPointer,
                    child: SingleChildScrollView(
                      key: ObjectKey(document),
                      controller: document.scroll,
                      physics: scripts?.hasModalDialog == true
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      child: document.content.isHtml
                          ? _buildContent(
                              document,
                              width: constraints.maxWidth,
                              height: constraints.maxHeight,
                              dark: base.brightness == Brightness.dark,
                            )
                          : (_body ??= _buildContent(document)),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: _scripts?.hasModalDialog == true
          ? {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  unawaited(_scripts!.requestModalClose()),
            }
          : const {},
      // A page on another origin is the page the user went to and loads its
      // own images; one the paired Gateway served is held content.
      child: NativeRemoteContentPolicy(
        loadOnActivation: document.pairedOrigin,
        child: page,
      ),
    );
  }

  Widget _buildContent(
    NativeFetchedDocument document, {
    double width = 390,
    double height = 844,
    bool dark = false,
  }) {
    final content = _scripts?.content ?? document.content;
    if (documentIsAttachment(document.headers)) {
      final download = NativeDocumentDownload(
        bytes: document.bytes,
        name: documentDownloadName(document.url, document.headers),
        mimeType: document.mimeType,
      );
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(download.name),
            const SizedBox(height: 12),
            WebButton(
              tr("儲存檔案"),
              onPressed: () => guarded(context, () async {
                final scope = NativeDocumentScope.maybeOf(context);
                final account = scope?.windows.accountIdentity;
                final connection = scope == null
                    ? obj(await widget.gateway.call('boot'))
                    : await scope.windows.connection();
                if (!mounted ||
                    (scope != null &&
                        (account != scope.windows.accountIdentity ||
                            scope.window?.disposed == true))) {
                  return;
                }
                await download.save(
                  widget.gateway,
                  '${connection['pairingStamp']}',
                );
              }),
            ),
          ],
        ),
      );
    }
    if (document.mimeType.startsWith('image/')) {
      return NativeMarkdownImage(
        gateway: widget.gateway,
        source: Uri.dataFromBytes(document.bytes, mimeType: document.mimeType),
        borderRadius: 0,
      );
    }
    if (!content.isHtml) {
      if (!document.mimeType.startsWith('text/') &&
          document.mimeType != 'application/json' &&
          !document.mimeType.endsWith('+json')) {
        return Padding(
          padding: EdgeInsets.all(24),
          child: Text(tr("此內容格式目前無法呈現。")),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(8),
        child: SelectableText(
          content.text,
          style: const TextStyle(
            inherit: false,
            fontFamily: 'monospace',
            fontSize: 13,
            textBaseline: TextBaseline.alphabetic,
            height: kTextHeightNone,
            color: Colors.black,
          ),
        ),
      );
    }
    final parsed = html.parseFragment(content.bodyInnerHtml);
    for (final node in parsed.querySelectorAll(
      'script,style,head,title,meta,base,link',
    )) {
      node.remove();
    }
    final scriptedEmpty =
        content.hasScripts &&
        (parsed.text?.trim().isEmpty ?? true) &&
        parsed.querySelector('img,input,button,textarea,select,table,canvas') ==
            null;
    if (scriptedEmpty && _scripts == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _scripts?.loading == true
              ? tr("正在載入互動內容…")
              : (_scripts?.diagnostics.join('\n') ??
                    tr("此頁面由腳本產生內容，尚未完成原生呈現。")),
        ),
      );
    }
    final styled = html.parse(content.text);
    if (_scripts?.ready != true || _scripts?.content == null) {
      // Only the VM snapshot may nominate a top-layer dialog. Ignore markup
      // that tries to supply the renderer's private marker directly.
      for (final element in styled.querySelectorAll(
        '[data-pirc-dialog-modal]',
      )) {
        element.attributes.remove('data-pirc-dialog-modal');
      }
    }
    if (_scripts == null) {
      var sequence = 0;
      for (final element in styled.querySelectorAll('*')) {
        element.attributes['data-pirc-script-id'] =
            'native-static-${sequence++}';
      }
    }
    if (_scripts == null) document.disclosures.apply(styled);
    _renderedTargetRevision = document.fragmentTarget.revision;
    final targetId = _scripts?.fragmentTargetId;
    final fragmentTarget = _scripts == null
        ? document.fragmentTarget.resolve(
            styled,
            reveal: document.disclosures.reveal,
          )
        : targetId == null
        ? null
        : styled
              .querySelectorAll('*')
              .where((e) => e.attributes['data-pirc-script-id'] == targetId)
              .firstOrNull;
    final environment = _displayEnvironment(
      width: width,
      height: height,
      dark: dark,
    );
    final result = NativeDocumentStyleEngine(
      dialogDefaults: true,
      viewportHeight: environment.height,
      devicePixelRatio: environment.devicePixelRatio,
      reducedMotion: environment.reducedMotion,
      pointer: environment.pointer,
      hover: environment.hover,
      documentBaseUrl: _scripts?.documentBaseUrl ?? document.effectiveBase,
      fragmentTarget: fragmentTarget,
      stylesheets: _scripts?.stylesheets ?? document.stylesheets,
      viewportWidth: width,
      dark: dark,
    ).apply(styled);
    document.renderingDiagnostics = result.diagnostics
        .map((entry) => entry.toString())
        .toList();
    final declaredScheme =
        result.stylesByElement[styled.documentElement]?['color-scheme'] ??
        result.stylesByElement[styled.body]?['color-scheme'] ??
        'normal';
    final schemes = declaredScheme.toLowerCase().split(RegExp(r'\s+'));
    final schemeDark =
        schemes.contains('dark') && (dark || !schemes.contains('light'));
    final indexStyles = <String, Map<String, String>>{};
    var next = 0;
    for (final element in styled.querySelectorAll('*')) {
      final key = '${next++}';
      element.attributes['data-pirc-document-style'] = key;
      // Scripted DOM nodes retain only VM-owned IDs. Assigning new IDs when
      // the engine becomes ready would replace live editor identities.
      if (_scripts == null) {
        element.attributes['data-pirc-script-id'] = 'native-static-$key';
      }
      indexStyles[key] = Map.of(result.stylesByElement[element] ?? {});
      // Author inline declarations already participate in the cascade. Keeping
      // them here would let HtmlWidget override an external important winner.
      element.attributes.remove('style');
    }
    final fragments = document.viewport.indexDocument(styled);
    _fragmentKnownIds = {
      ...?_scripts?.layoutElementIds,
      ...styled
          .querySelectorAll('*')
          .map((element) => element.attributes['data-pirc-script-id'])
          .whereType<String>(),
    };
    _fragmentLayoutRevision = _scripts?.layoutRevision ?? 0;
    final root = styled.documentElement!;
    _fragmentRootId = root.attributes['data-pirc-script-id'];
    final body = styled.body!;
    final rootKey = root.attributes['data-pirc-document-style']!;
    final bodyKey = body.attributes['data-pirc-document-style']!;
    final rootStyles = indexStyles[rootKey]!;
    final bodyStyles = indexStyles[bodyKey]!;
    final bodyBackground = Map.fromEntries(
      bodyStyles.entries.where(
        (entry) =>
            entry.key == 'background' || entry.key.startsWith('background-'),
      ),
    );
    final rootHasBackground = rootStyles.entries.any((entry) {
      if (!const {
        'background',
        'background-color',
        'background-image',
      }.contains(entry.key)) {
        return false;
      }
      final value = entry.value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      return !const {
        'none',
        'transparent',
        'rgba(0,0,0,0)',
        '#0000',
        '#00000000',
      }.contains(value);
    });
    if (!rootHasBackground) {
      rootStyles.addAll(bodyBackground);
      for (final key in bodyBackground.keys) {
        bodyStyles.remove(key);
      }
    }
    // These are UA defaults and only fill properties absent from author CSS.
    indexStyles[bodyKey] = {'margin': '8px', ...bodyStyles};
    String attrs(Map<Object, String> attributes) => attributes.entries
        .map((e) => ' ${e.key}="${const HtmlEscape().convert(e.value)}"')
        .join();
    Color? canvasColor;
    final canvasBackground = rootStyles['background-color'];
    if (canvasBackground != null && canvasBackground != 'transparent') {
      try {
        final color = css_parser.Color.css(canvasBackground).rgba;
        canvasColor = Color.fromRGBO(
          color.r,
          color.g,
          color.b,
          (color.a ?? 1).toDouble(),
        );
      } catch (_) {
        document.renderingDiagnostics.add(
          tr("Document canvas color is not supported: {0}", [canvasBackground]),
        );
      }
    }
    final markup =
        '<div${attrs(root.attributes)}>'
        '<div${attrs(body.attributes)}>${body.innerHtml}</div></div>';
    final noBoxIds = nativeDocumentNoBoxIds(
      document: styled,
      knownIds: _fragmentKnownIds,
      stylesByElement: result.stylesByElement,
    );
    final computedStyles = nativeDocumentComputedStyleSpecs(
      document: styled,
      stylesByElement: result.stylesByElement,
      canvasBitmapAttributesIndependent:
          result.canvasBitmapAttributesIndependent,
      inlineBoxStyleOverridesIndependent:
          result.inlineBoxStyleOverridesIndependent,
      textContentSelectorsIndependent: result.textContentSelectorsIndependent,
      viewportWidth: environment.width,
      viewportHeight: environment.height,
      dark: schemeDark,
    );
    _viewportScrollBehavior =
        computedStyles[root.attributes['data-pirc-script-id']]
            ?.values['scroll-behavior'] ??
        'auto';
    _scrollAnchors.nodes = nativeDocumentScrollAnchorNodes(
      document: styled,
      stylesByElement: result.stylesByElement,
      computedStyles: computedStyles,
    );
    final rendered = NativeHtmlDocument(
      layoutController: _layout,
      elementScrollController: _elementScroll,
      layoutRevision: _scripts?.layoutRevision ?? 0,
      layoutKnownIds: _fragmentKnownIds,
      layoutNoBoxIds: noBoxIds,
      layoutComputedStyles: computedStyles,
      documentPercentTopMargins: nativeDocumentPercentTopMarginGroups(
        document: styled,
        stylesByElement: result.stylesByElement,
      ),
      documentTopMargins: nativeDocumentCollapsedTopMargins(
        document: styled,
        stylesByElement: result.stylesByElement,
      ),
      layoutOffsetSpecs: nativeDocumentOffsetSpecs(
        document: styled,
        stylesByElement: result.stylesByElement,
        computedStyles: computedStyles,
      ),
      nodes: [NativeHtmlRaw(markup)],
      authorStylesBuilder: (element) =>
          indexStyles[element.attributes['data-pirc-document-style']],
      style: TextStyle(
        inherit: false,
        fontFamily: 'serif',
        fontSize: 16,
        height: kTextHeightNone,
        color: schemeDark ? Colors.white : Colors.black,
        letterSpacing: 0,
      ),
      styles: MarkdownStyleSheet(),
      builders: const {},
      markdownStyles: false,
      imageViewport: Size(
        width,
        height.isFinite ? height : MediaQuery.sizeOf(context).height,
      ),
      imageDark: dark,
      viewport: document.viewport,
      fragmentIndex: fragments,
      historyController: document.historyControls,
      preserveControlValues: _scripts == null,
      retainedControls: _scripts == null ? document.liveControls : null,
      onNavigate: widget.onLink,
      onFormSubmit: widget.onSubmit,
      onDetailsActivate: _scripts != null
          ? null
          : (id) {
              if (!mounted ||
                  !identical(widget.document, document) ||
                  _scripts != null) {
                return;
              }
              if (document.disclosures.toggle(id)) setState(() {});
            },
      onScriptEvent: _scripts?.dispatch,
      onScriptDetailedEvent: _scripts == null
          ? null
          : _dispatchNativeDetailedEvent,
      onScriptTouchClickQueued: _scripts == null
          ? null
          : _nativeTouchClickQueued,
      onScriptControlClick: _scripts?.ready == true ? _scripts!.click : null,
      scriptFocusActions: _scripts?.focusActions ?? const [],
      takeScriptFocusActions: _scripts?.takeFocusActions,
      scriptFilePickerActions: _scripts?.filePickerActions ?? const [],
      takeScriptFilePickerActions: _scripts?.takeFilePickerActions,
      onScriptFilePickerResult: _scripts?.completeFilePicker,
      scriptFilePickerIsCurrent: _scripts == null
          ? null
          : _scriptPickerScope(document, _scope),
      scriptFileSelections: document.scriptFileSelections,
      scriptFormActions: _scripts?.formActions ?? const [],
      onScriptFormActionsConsumed: _scripts?.acknowledgeFormActions,
      takeScriptFormActions: _scripts?.takeFormActions,
      scriptDocument: document,
      scriptSnapshot: _scripts?.content,
      onScriptRestoreControls: _scripts?.restoreControls,
      canvases: _scripts?.canvases ?? const {},
      canvasImages: _scripts?.canvasImages ?? const {},
      vectorImageSources: _scripts?.vectorImageSources ?? const {},
      htmlImages: _scripts?.htmlImages ?? const {},
      deferImageLoading:
          _scripts != null &&
          !_scripts!.ready &&
          _scripts!.initialTargetSelectionPending,
      imageBuilder: (uri, title, alt) => NativeMarkdownImage(
        gateway: widget.gateway,
        source: uri,
        title: title,
        alt: alt,
        baseUrl: document.effectiveBase,
        borderRadius: 0,
      ),
    );
    final theme = Theme.of(context);
    final brightness = schemeDark ? Brightness.dark : Brightness.light;
    return Theme(
      data: theme.copyWith(
        brightness: brightness,
        colorScheme: theme.colorScheme.copyWith(brightness: brightness),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: ColoredBox(
          color: canvasColor ?? Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_scripts?.loading == true)
                Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(tr("正在載入互動內容…")),
                ),
              if (_scripts?.diagnostics.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _scripts!.diagnostics.join('\n'),
                    style: const TextStyle(
                      fontFamily: 'sans-serif',
                      fontSize: 13,
                    ),
                  ),
                ),
              if (_objectUrls case final binding?)
                NativeDocumentObjectUrlScope(binding: binding, child: rendered)
              else
                rendered,
            ],
          ),
        ),
      ),
    );
  }
}

/// Owns an initial submission's lifetime without creating network work during
/// ordinary rich-text builds. App-scoped windows outlive individual messages.
class NativeDocumentSubmissionHost extends StatefulWidget {
  const NativeDocumentSubmissionHost({
    super.key,
    required this.gateway,
    required this.builder,
  });
  final Gateway gateway;
  final Widget Function(ValueChanged<NativeHtmlFormSubmission>) builder;
  @override
  State<NativeDocumentSubmissionHost> createState() =>
      _NativeDocumentSubmissionHostState();
}

class _NativeDocumentSubmissionHostState
    extends State<NativeDocumentSubmissionHost> {
  NativeDocumentWindows? _local;
  int _ticket = 0;
  NativeDocumentScope? _lastScope;
  final Map<NativeDocumentWindow, int> _pending = {};
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = NativeDocumentScope.maybeOf(context);
    if (_lastScope != null &&
        (_lastScope!.documentUrl != next?.documentUrl ||
            _lastScope!.accountIdentity != next?.accountIdentity)) {
      _cancelInitial();
    }
    _lastScope = next;
  }

  void _cancelInitial() {
    _ticket++;
    for (final entry in _pending.entries) {
      if (!entry.key.disposed &&
          entry.key.loading &&
          !entry.key.windows.presented) {
        entry.key.stop(expectedGeneration: entry.value);
      }
    }
    _pending.clear();
  }

  Future<void> _submit(
    NativeHtmlFormSubmission submission,
    NativeDocumentScope? captured,
  ) async {
    final ticket = ++_ticket;
    final windows =
        captured?.windows ?? (_local ??= NativeDocumentWindows(widget.gateway));
    final identity = captured?.accountIdentity ?? windows.accountIdentity;
    if (identity != windows.accountIdentity) return;
    try {
      var url = captured?.documentUrl;
      if (url == null) {
        final boot = await windows.connection();
        url = '${boot['origin']}/';
      }
      if (!mounted ||
          ticket != _ticket ||
          identity != windows.accountIdentity) {
        return;
      }
      final scope =
          captured ??
          NativeDocumentScope(
            windows: windows,
            documentUrl: url,
            sourceIdentity: identity,
            child: const SizedBox(),
          );
      final request = submission.buildRequest(documentUrl: url);
      NativeDocumentWindow? started;
      final opened = openNativeDocument(
        context,
        scope,
        request,
        onStarted: (window) {
          started = window;
          _pending[window] = window.navigationGeneration;
        },
      );
      await opened;
      if (started != null) _pending.remove(started);
    } catch (e) {
      if (mounted && ticket == _ticket) {
        showNotice(context, LiveController.describe(e));
      }
    } finally {
      if (!mounted && _local?.presented == false) {
        _local?.dispose();
        _local = null;
      }
    }
  }

  @override
  void dispose() {
    _cancelInitial();
    if (_local?.presented != true) {
      _local?.dispose();
      _local = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final captured = NativeDocumentScope.maybeOf(context);
    return widget.builder((s) => unawaited(_submit(s, captured)));
  }
}

Future<void> showNativeDocumentWindowManager(
  BuildContext context,
  NativeDocumentWindows windows,
  NativeDocumentHostState host,
) async {
  final appNavigator = Navigator.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final account = windows.accountIdentity;
  await navigator.push<void>(
    MaterialPageRoute(
      builder: (_) => NativeDocumentWindowManagerPage(
        windows: windows,
        onSelect: (window) async {
          await host.selectWindow(window);
          if (navigator.mounted &&
              !windows.disposed &&
              account == windows.accountIdentity &&
              windows.active == window) {
            if (appNavigator.mounted && appNavigator != navigator) {
              appNavigator.popUntil((route) => route.isFirst);
            }
            navigator.popUntil((route) => route.isFirst);
          }
        },
        onClose: host.closeWindow,
        onBack: (window) async {
          await host.selectWindow(window);
          if (!windows.disposed &&
              windows.active == window &&
              account == windows.accountIdentity) {
            await host.back();
          }
        },
        onForward: (window) async {
          await host.selectWindow(window);
          if (!windows.disposed &&
              windows.active == window &&
              account == windows.accountIdentity) {
            await host.forward();
          }
        },
      ),
    ),
  );
}

class _NativeHistoryPostResubmissionPage extends StatelessWidget {
  const _NativeHistoryPostResubmissionPage();

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return LayoutBuilder(
      builder: (context, size) {
        final width = size.maxWidth;
        final height = size.maxHeight;
        final portrait = height >= width;
        final mobile = width <= 420 && portrait || height <= 560;
        var top = height * .14;
        if (mobile) top = height * .07;
        if (width > 420 && height >= 500 && height <= 560 ||
            width <= 414 && portrait && height >= 650) {
          top = height * .10;
        }
        final maxWidth = width <= 420 && height >= 401 ? 736.0 : 600.0;
        final wrapperWidth = width.clamp(0.0, maxWidth);
        final side = mobile
            ? 24.0
            : width <= 700
            ? wrapperWidth * .10
            : 0.0;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final text = dark ? const Color(0xff9aa0a6) : const Color(0xff5f6368);
        final heading = dark ? text : const Color(0xff202124);
        TextStyle style(double fontSize, double lineHeight, Color color) =>
            TextStyle(
              fontFamily: 'system-ui',
              fontFamilyFallback: [
                tr("PingFang TC"),
                tr("Heiti TC"),
                'sans-serif',
              ],
              fontSize: fontSize,
              height: lineHeight / fontSize,
              fontWeight: FontWeight.w400,
              color: color,
            );
        return ColoredBox(
          color: dark ? const Color(0xff202124) : Colors.white,
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              top: top,
              bottom: portrait && height >= 400 ? 145 : 40,
            ),
            child: Center(
              child: SizedBox(
                width: wrapperWidth,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: side),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ExcludeSemantics(
                        child: SizedBox(
                          width: 72,
                          height: 72,
                          child: CustomPaint(painter: _NativePostErrorIcon()),
                        ),
                      ),
                      SizedBox(height: (mobile ? height * .0569 : 40) + 6),
                      Text(
                        tr("確認重新提交表單"),
                        style: style(
                          mobile ? 22.5 : 24,
                          mobile ? 28.125 : 30,
                          heading,
                        ),
                      ),
                      SizedBox(height: mobile ? 15 : 16),
                      Text(
                        tr(
                          "這個網頁需要使用你先前輸入的資料才能正確顯示。你可以重新傳送這些資料，不過這麼做會重複執行這個網頁先前執行過的任何動作。",
                        ),
                        style: style(14.25, 22.9425, text),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr("按下重新載入按鈕，重新提交載入網頁所需的資料。"),
                        style: style(15, 24, text),
                      ),
                      const SizedBox(height: 12),
                      Text('ERR_CACHE_MISS', style: style(12, 24, text)),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Native line art for the browser's failed-document status icon.
class _NativePostErrorIcon extends CustomPainter {
  const _NativePostErrorIcon();
  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..color = const Color(0xff535353)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(1.5, 31.5)
        ..lineTo(24, 31.5)
        ..lineTo(31, 38.5)
        ..lineTo(31, 70.5)
        ..lineTo(1.5, 70.5)
        ..close(),
      outline,
    );
    canvas.drawPath(
      Path()
        ..moveTo(23, 31.5)
        ..lineTo(23, 40)
        ..lineTo(31, 40),
      outline,
    );
    final pixels = Paint()..color = const Color(0xff535353);
    canvas.drawRect(const Rect.fromLTWH(9, 45, 3, 3), pixels);
    canvas.drawRect(const Rect.fromLTWH(21, 45, 3, 3), pixels);
    canvas.drawRect(const Rect.fromLTWH(11, 58, 11, 3), pixels);
    canvas.drawRect(const Rect.fromLTWH(9, 61, 3, 3), pixels);
    canvas.drawRect(const Rect.fromLTWH(21, 61, 3, 3), pixels);
  }

  @override
  bool shouldRepaint(_NativePostErrorIcon oldDelegate) => false;
}
