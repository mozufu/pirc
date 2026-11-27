import 'dart:async';
import 'dart:io' show HttpDate;
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:pirc_render_document/src/document_json.dart';
import 'package:pirc_render_document/src/scripts_platform.dart';

export 'package:pirc_render_document/src/document_json.dart';

/// A [ScriptsPlatform] for the tests moved from the old app, which faked the
/// old Kotlin bridge as `Gateway.call(method, arguments)`. Each channel call
/// becomes one [call] with the old method name, so those fakes keep working:
///
/// - `capabilities` → `documentScriptCapabilities` (`canvasTextSupported`)
/// - `open` → `documentScriptOpen {owner}` → `{id}`
/// - `loadRuntime` → `documentScriptEvaluate {source: runtimeSource}`, as the
///   old app evaluated the runtime source itself
/// - `canvasText` → `documentScriptCanvasText` → `{value}`
/// - `evaluate` → `documentScriptEvaluate {source}` → `{value}`
/// - `storage` and `cookies` stay here, per session (see [storeCalls])
/// - `resource` → `documentScriptResource {request}` → the response wire
/// - `cancelResource`, `close` → `documentScriptResourceCancel`,
///   `documentScriptClose`
///
/// It follows the Kotlin channel (`DocumentScripts.kt`, `DocumentStores.kt`,
/// `ScriptResources.kt`) where the old fakes cannot:
/// - each open session has its own ID, even when a fake answers a fixed
///   one, and its own storage and cookies, cleared when it closes;
/// - a call for a closed session fails with `SCRIPT_CLOSED`, one with the
///   wrong owner with `SCRIPT_OWNER`; a timeout retires the session;
/// - cookies follow `DocumentCookies` (no name-only `HttpOnly` or prefixed
///   cookies, deletion by `Max-Age`/`Expires`, at most 50);
/// - a request over [maxInFlight], or with an ID already in flight, is
///   refused; a `no-cors` response is opaque.
abstract class LegacyScriptsPlatform implements ScriptsPlatform {
  /// What `loadRuntime` evaluates.
  String runtimeSource = 'runtime';

  /// The channel's cap per document (`ScriptResources.MAX_IN_FLIGHT`).
  static const maxInFlight = 6;
  final _inFlight = <int, int>{};

  /// The most requests one session had in flight at once.
  int peakInFlight = 0;

  /// Old fakes overrode the Gateway event stream; nothing listens now.
  Stream<Json> get events => const Stream.empty();

  /// The old bridge call. Subclasses answer as the old fakes did.
  Future<dynamic> call(String method, [Json args = const {}]);

  Json _session(DocumentScriptSession session) => {
    'id': session.id,
    'owner': session.owner,
  };

  /// The open sessions by ID, with their owners.
  final _open = <int, String>{};

  /// IDs of requests in flight, per session.
  final _requestIds = <int, Set<String>>{};

  /// As `DocumentScripts.session`: the session must be open and owned.
  void _check(DocumentScriptSession session) {
    final owner =
        _open[session.id] ??
        (throw PlatformException(
          code: ScriptsError.closed,
          message: 'The document script session is closed.',
        ));
    if (owner != session.owner) {
      throw PlatformException(
        code: ScriptsError.owner,
        message: 'The document does not match.',
      );
    }
  }

  void _retire(int id) {
    _open.remove(id);
    _local.remove(id);
    _sessionAreas.remove(id);
    _cookies.remove(id);
  }

  @override
  Future<DocumentScriptCapabilities> capabilities() async {
    final wire = obj(await call('documentScriptCapabilities'));
    return DocumentScriptCapabilities(
      supported: wire['supported'] == true,
      canvasText: wire['canvasTextSupported'] == true,
      reason: wire['reason'] as String?,
    );
  }

  @override
  Future<DocumentScriptSession> open() async {
    final owner = List.generate(
      24,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final wire = obj(await call('documentScriptOpen', {'owner': owner}));
    var id = wire['id'];
    if (id is! int) throw const FormatException('Invalid script identity.');
    // Kotlin gives every open session its own ID.
    while (_open.containsKey(id)) {
      id = (id as int) + 1;
    }
    _open[id as int] = owner;
    return DocumentScriptSession(id, owner);
  }

  @override
  Future<void> loadRuntime(DocumentScriptSession session) async {
    _check(session);
    await _evaluateCall(session, runtimeSource);
  }

  @override
  Future<String> canvasText(
    DocumentScriptSession session, {
    required List<String> families,
    required String sample,
  }) async {
    _check(session);
    return _value(
      await call('documentScriptCanvasText', {
        ..._session(session),
        'families': families,
        'sample': sample,
      }),
    );
  }

  /// Whether the runtime's storage and cookie sync calls reach [call]. The
  /// old app sent none for its fakes' documents, so they stay here unless a
  /// test asks for them; they answer as the runtime does.
  bool forwardStoreEvaluations = false;

  @override
  Future<String> evaluate(DocumentScriptSession session, String source) async {
    _check(session);
    if (!forwardStoreEvaluations &&
        (source.startsWith('__pircDocument.storageSync') ||
            source.startsWith('__pircDocument.storageEntry') ||
            source.startsWith('__pircDocument.syncCookies('))) {
      storeCalls.add(('evaluate', session.id, source));
      return '{"ok":true}';
    }
    return _evaluateCall(session, source);
  }

  Future<String> _evaluateCall(
    DocumentScriptSession session,
    String source,
  ) async {
    try {
      return _value(
        await call('documentScriptEvaluate', {
          ..._session(session),
          'source': source,
        }),
      );
    } on PlatformException catch (error) {
      // A runaway script loses its isolate, as in Kotlin.
      if (error.code == ScriptsError.timeout ||
          error.code == ScriptsError.closed) {
        _retire(session.id);
      }
      rethrow;
    }
  }

  static String _value(dynamic response) {
    final value = obj(response)['value'];
    if (value is! String) throw const FormatException('Invalid script result.');
    return value;
  }

  /// Storage and cookies are kept here per session, in memory, as Kotlin
  /// does: the old bridge shapes for them are gone. Calls are logged in
  /// [storeCalls] as `(method, session id, argument)`.
  final storeCalls = <(String, int, Object)>[];
  final _local = <int, Map<String, String>>{};
  final _sessionAreas = <int, Map<String, String>>{};
  final _cookies = <int, Map<String, (String, DateTime?)>>{};

  @override
  Future<DocumentStorageState> storage(
    DocumentScriptSession session, [
    List<DocumentStorageOperation> operations = const [],
  ]) async {
    _check(session);
    storeCalls.add(('storage', session.id, operations));
    // A write over the quota fails as a whole, as `DocumentStorage.apply`.
    final local = Map<String, String>.of(_local[session.id] ?? const {});
    final areas = Map<String, String>.of(_sessionAreas[session.id] ?? const {});
    int size(Map<String, String> area) =>
        area.entries.fold(0, (sum, e) => sum + e.key.length + e.value.length);
    for (final operation in operations) {
      final area = operation.area == 'local' ? local : areas;
      switch (operation.op) {
        case 'set':
          area[operation.key!] = operation.value!;
        case 'remove':
          area.remove(operation.key);
        case 'clear':
          area.clear();
      }
      if (size(area) > storageQuotaChars) {
        throw PlatformException(code: ScriptsError.storageQuota);
      }
    }
    _local[session.id] = local;
    _sessionAreas[session.id] = areas;
    return DocumentStorageState(local: Map.of(local), session: Map.of(areas));
  }

  @override
  Future<String> cookies(
    DocumentScriptSession session, [
    List<String> writes = const [],
  ]) async {
    _check(session);
    storeCalls.add(('cookies', session.id, writes));
    final jar = _cookies[session.id] ??= {};
    for (final line in writes) {
      _assignCookie(jar, line);
    }
    final now = DateTime.now();
    jar.removeWhere(
      (_, cookie) => cookie.$2 != null && !cookie.$2!.isAfter(now),
    );
    return [
      for (final MapEntry(:key, value: (value, _)) in jar.entries)
        key.isEmpty ? value : '$key=$value',
    ].join('; ');
  }

  /// `DocumentStorage.QUOTA_CHARS`.
  static const storageQuotaChars = 5 * 1024 * 1024 ~/ 2;

  /// `DocumentCookies.MAX_COOKIES`.
  static const maxCookies = 50;

  /// `DocumentCookies.assign`: RFC 6265 § 5.2 for a document without a URL.
  static void _assignCookie(Map<String, (String, DateTime?)> jar, String line) {
    if (line.length > 4096 ||
        line.codeUnits.any((c) => c < 0x20 && c != 0x09 || c == 0x7f)) {
      return;
    }
    final parts = line.split(';');
    final pair = parts.first;
    final equals = pair.indexOf('=');
    final name = equals < 0 ? '' : pair.substring(0, equals).trim();
    final value = (equals < 0 ? pair : pair.substring(equals + 1)).trim();
    if (name.isEmpty && value.isEmpty) return;
    final lower = name.toLowerCase();
    if (lower.startsWith('__secure-') || lower.startsWith('__host-')) return;
    DateTime? expires;
    var maxAgeSeen = false;
    final now = DateTime.now();
    for (final attribute in parts.skip(1)) {
      final at = attribute.indexOf('=');
      final key = (at < 0 ? attribute : attribute.substring(0, at))
          .trim()
          .toLowerCase();
      final raw = at < 0 ? '' : attribute.substring(at + 1).trim();
      switch (key) {
        case 'httponly':
          return;
        case 'max-age':
          final seconds = int.tryParse(raw);
          if (seconds != null) {
            maxAgeSeen = true;
            expires = seconds <= 0
                ? DateTime.fromMillisecondsSinceEpoch(0)
                : now.add(Duration(seconds: min(seconds, 400 * 24 * 60 * 60)));
          }
        case 'expires' when !maxAgeSeen:
          try {
            expires = HttpDate.parse(raw);
          } on FormatException {
            // Ignored, as Kotlin ignores an unparsable date.
          }
      }
    }
    if (expires != null && !expires.isAfter(now)) {
      jar.remove(name);
      return;
    }
    if (!jar.containsKey(name) && jar.length >= maxCookies) return;
    jar[name] = (value, expires);
  }

  @override
  Future<DocumentResourceResponse> resource(
    DocumentScriptSession session,
    DocumentResourceRequest request,
  ) async {
    _check(session);
    final ids = _requestIds[session.id] ??= {};
    if (ids.contains(request.id)) {
      throw PlatformException(
        code: ScriptsError.resource,
        message: 'The request ID ${request.id} is already in use.',
      );
    }
    final active = (_inFlight[session.id] ?? 0) + 1;
    if (active > maxInFlight) {
      throw PlatformException(
        code: ScriptsError.resource,
        message: 'A document may have at most $maxInFlight requests at once.',
      );
    }
    _inFlight[session.id] = active;
    ids.add(request.id);
    peakInFlight = max(peakInFlight, active);
    try {
      final wire = obj(
        await call('documentScriptResource', {
          ..._session(session),
          'request': request.toWire(),
        }),
      );
      final raw = wire['bodyBytes'];
      final body = raw is List && raw is! Uint8List
          ? Uint8List.fromList(raw.cast<int>())
          : raw as Uint8List?;
      _check(session);
      final status = wire['status'] as int? ?? 200;
      if (request.mode == 'no-cors') {
        // `ScriptResources.respond`: the script learns nothing; a classic
        // script or stylesheet still reaches the runtime.
        final content =
            request.kind == 'script' || request.kind == 'stylesheet';
        return DocumentResourceResponse(
          status: content ? status : 0,
          statusText: '',
          url: content ? '${wire['url'] ?? request.url}' : '',
          headers: const [],
          body: content && status >= 200 && status < 300 ? body : null,
          type: 'opaque',
          redirected: false,
          mimeType: content ? '${wire['mimeType'] ?? ''}' : '',
          charset: content ? wire['charset'] as String? : null,
          originClean: false,
        );
      }
      return DocumentResourceResponse.fromWire({
        'statusText': '',
        ...wire,
        'status': status,
        'type': 'cors',
        'originClean': true,
        'bodyBytes': body,
      });
    } finally {
      _inFlight[session.id] = _inFlight[session.id]! - 1;
      ids.remove(request.id);
    }
  }

  @override
  Future<void> cancelResource(
    DocumentScriptSession session,
    String requestId,
  ) async {
    // As Kotlin: nothing to cancel for a closed session.
    if (!_open.containsKey(session.id)) return;
    _check(session);
    await call('documentScriptResourceCancel', {
      ..._session(session),
      'requestId': requestId,
    });
  }

  @override
  Future<DocumentMediaBytes> media(Uri url, {required String requestId}) =>
      throw UnsupportedError('media');

  @override
  Future<void> cancelMedia(String requestId) async {}

  @override
  Future<void> close(DocumentScriptSession session) async {
    await call('documentScriptClose', _session(session));
    _check(session);
    _retire(session.id);
  }

  @override
  Future<void> closeAll() async {
    for (final id in _open.keys.toList()) {
      _retire(id);
    }
  }
}
