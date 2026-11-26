import 'dart:math';

import 'package:flutter/services.dart';

/// Scripts of documents that come from a message or a tool result, through
/// the `org.mozufu.pirc/scripts` channel (Android, plans/roadmap.md M8 step 6).
///
/// Such a document runs with an opaque origin in its own JavaScript isolate.
/// Kotlin gives each session its own storage and cookies, which no other
/// session can name and which end with the session. Requests go out without
/// credentials: this interface has no way to pass the device token, a Gateway
/// cookie or an `Authorization` header, and [DocumentResourceRequest] refuses
/// credential headers before anything is sent.
abstract interface class ScriptsPlatform {
  Future<DocumentScriptCapabilities> capabilities();

  /// A new isolate for one document.
  Future<DocumentScriptSession> open();

  /// Runs the packaged document runtime (Kotlin reads it from the APK).
  Future<void> loadRuntime(DocumentScriptSession session);

  /// Loads the Canvas text engine and system fonts into the isolate and
  /// returns the JSON result of its set-up. The fonts stay in Kotlin.
  Future<String> canvasText(
    DocumentScriptSession session, {
    required List<String> families,
    required String sample,
  });

  /// Runs [source] (at most 4 MiB, 2 seconds) and returns its result.
  Future<String> evaluate(DocumentScriptSession session, String source);

  /// Applies [operations] to this document's storage; returns both areas.
  Future<DocumentStorageState> storage(
    DocumentScriptSession session, [
    List<DocumentStorageOperation> operations = const [],
  ]);

  /// Applies `document.cookie` assignments; returns `document.cookie`.
  Future<String> cookies(
    DocumentScriptSession session, [
    List<String> writes = const [],
  ]);

  Future<DocumentResourceResponse> resource(
    DocumentScriptSession session,
    DocumentResourceRequest request,
  );
  Future<void> cancelResource(DocumentScriptSession session, String requestId);

  /// The bytes of a media element the user tapped, fetched without
  /// credentials, from a public address only.
  Future<DocumentMediaBytes> media(Uri url, {required String requestId});
  Future<void> cancelMedia(String requestId);

  Future<void> close(DocumentScriptSession session);

  /// Closes every session (unpairing).
  Future<void> closeAll();
}

/// Error codes of the channel's [PlatformException]s.
abstract final class ScriptsError {
  static const invalid = 'INVALID';
  static const unsupported = 'SCRIPT_UNSUPPORTED';
  static const closed = 'SCRIPT_CLOSED';
  static const owner = 'SCRIPT_OWNER';
  static const capacity = 'SCRIPT_CAPACITY';
  static const timeout = 'SCRIPT_TIMEOUT';
  static const limit = 'SCRIPT_LIMIT';
  static const evaluation = 'SCRIPT_EVALUATION';
  static const engine = 'SCRIPT_ENGINE';
  static const storageQuota = 'STORAGE_QUOTA';
  static const resource = 'RESOURCE';
}

class DocumentScriptCapabilities {
  const DocumentScriptCapabilities({
    required this.supported,
    this.canvasText = false,
    this.reason,
  });
  final bool supported;
  final bool canvasText;
  final String? reason;
}

/// One open document. [owner] is a random value only this app knows; Kotlin
/// refuses a call whose owner does not match the session.
class DocumentScriptSession {
  const DocumentScriptSession(this.id, this.owner);
  final int id;
  final String owner;

  /// The document's origin: always opaque.
  String get origin => 'null';
}

class DocumentStorageOperation {
  const DocumentStorageOperation.set(
    this.area,
    String this.key,
    String this.value,
  ) : op = 'set';
  const DocumentStorageOperation.remove(this.area, String this.key)
    : op = 'remove',
      value = null;
  const DocumentStorageOperation.clear(this.area)
    : op = 'clear',
      key = null,
      value = null;

  /// `local` or `session`.
  final String area;
  final String op;
  final String? key;
  final String? value;

  Map<String, Object?> toWire() => {
    'area': area,
    'op': op,
    'key': ?key,
    'value': ?value,
  };
}

class DocumentStorageState {
  const DocumentStorageState({required this.local, required this.session});
  final Map<String, String> local;
  final Map<String, String> session;
}

/// A network request of a document script.
class DocumentResourceRequest {
  DocumentResourceRequest({
    required this.id,
    required Uri url,
    this.method = 'GET',
    this.headers = const [],
    this.body,
    this.kind = 'fetch',
    this.mode,
    this.redirect = 'follow',
  }) : url = url.toString() {
    if (!url.isAbsolute || !const {'http', 'https'}.contains(url.scheme)) {
      throw ArgumentError.value(url, 'url', 'needs an absolute http(s) URL');
    }
    if (!const {'fetch', 'script', 'module', 'stylesheet'}.contains(kind)) {
      // Images wait for a tap; they are never a script resource.
      throw ArgumentError.value(kind, 'kind');
    }
    for (final (name, _) in headers) {
      if (credentialHeaders.contains(name.toLowerCase())) {
        throw ArgumentError.value(name, 'headers', 'carries credentials');
      }
    }
  }

  /// Headers a message document may never send.
  static const credentialHeaders = {
    'authorization',
    'cookie',
    'cookie2',
    'proxy-authorization',
  };

  final String id;
  final String url;
  final String method;
  final List<(String, String)> headers;
  final Uint8List? body;
  final String kind;
  final String? mode;
  final String redirect;

  Map<String, Object?> toWire() => {
    'id': id,
    'url': url,
    'method': method,
    'headers': [
      for (final (name, value) in headers) [name, value],
    ],
    'bodyBytes': ?body,
    'kind': kind,
    'mode': ?mode,
    'redirect': redirect,
  };
}

class DocumentResourceResponse {
  const DocumentResourceResponse({
    required this.status,
    required this.statusText,
    required this.url,
    required this.headers,
    required this.body,
    required this.type,
    required this.redirected,
    required this.mimeType,
    this.charset,
    required this.originClean,
  });

  factory DocumentResourceResponse.fromWire(Map<Object?, Object?> wire) =>
      DocumentResourceResponse(
        status: wire['status'] as int,
        statusText: wire['statusText'] as String? ?? '',
        url: wire['url'] as String? ?? '',
        headers: [
          for (final pair in wire['headers'] as List? ?? const [])
            ((pair as List)[0] as String, pair[1] as String),
        ],
        body: wire['bodyBytes'] as Uint8List?,
        type: wire['type'] as String,
        redirected: wire['redirected'] as bool? ?? false,
        mimeType: wire['mimeType'] as String? ?? '',
        charset: wire['charset'] as String?,
        originClean: wire['originClean'] as bool? ?? false,
      );

  final int status;
  final String statusText;
  final String url;
  final List<(String, String)> headers;
  final Uint8List? body;

  /// `cors`, `opaque` or `opaqueredirect`.
  final String type;
  final bool redirected;
  final String mimeType;
  final String? charset;
  final bool originClean;
}

class DocumentMediaBytes {
  const DocumentMediaBytes(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

String _newOwner() {
  final random = Random.secure();
  return [
    for (var i = 0; i < 24; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

class ChannelScriptsPlatform implements ScriptsPlatform {
  const ChannelScriptsPlatform([
    this.channel = const MethodChannel('org.mozufu.pirc/scripts'),
  ]);

  final MethodChannel channel;

  Map<String, Object?> _session(DocumentScriptSession session) => {
    'id': session.id,
    'owner': session.owner,
  };

  Future<Map<Object?, Object?>> _map(
    String method, [
    Map<String, Object?>? arguments,
  ]) async =>
      (await channel.invokeMapMethod<Object?, Object?>(method, arguments))!;

  @override
  Future<DocumentScriptCapabilities> capabilities() async {
    final wire = await _map('capabilities');
    return DocumentScriptCapabilities(
      supported: wire['supported'] == true,
      canvasText: wire['canvasText'] == true,
      reason: wire['reason'] as String?,
    );
  }

  @override
  Future<DocumentScriptSession> open() async {
    final owner = _newOwner();
    final wire = await _map('open', {'owner': owner});
    return DocumentScriptSession(wire['id'] as int, owner);
  }

  @override
  Future<void> loadRuntime(DocumentScriptSession session) =>
      channel.invokeMethod<void>('runtime', _session(session));

  @override
  Future<String> canvasText(
    DocumentScriptSession session, {
    required List<String> families,
    required String sample,
  }) async =>
      (await _map('canvasText', {
            ..._session(session),
            'families': families,
            'sample': sample,
          }))['value']
          as String;

  @override
  Future<String> evaluate(DocumentScriptSession session, String source) async =>
      (await _map('evaluate', {
            ..._session(session),
            'source': source,
          }))['value']
          as String;

  @override
  Future<DocumentStorageState> storage(
    DocumentScriptSession session, [
    List<DocumentStorageOperation> operations = const [],
  ]) async {
    final wire = await _map('storage', {
      ..._session(session),
      'operations': [for (final operation in operations) operation.toWire()],
    });
    Map<String, String> area(Object? value) =>
        (value as Map? ?? const {}).cast<String, String>();
    return DocumentStorageState(
      local: area(wire['local']),
      session: area(wire['session']),
    );
  }

  @override
  Future<String> cookies(
    DocumentScriptSession session, [
    List<String> writes = const [],
  ]) async =>
      (await _map('cookies', {
            ..._session(session),
            'writes': writes,
          }))['cookie']
          as String;

  @override
  Future<DocumentResourceResponse> resource(
    DocumentScriptSession session,
    DocumentResourceRequest request,
  ) async => DocumentResourceResponse.fromWire(
    await _map('resource', {..._session(session), 'request': request.toWire()}),
  );

  @override
  Future<void> cancelResource(
    DocumentScriptSession session,
    String requestId,
  ) => channel.invokeMethod<void>('resourceCancel', {
    ..._session(session),
    'requestId': requestId,
  });

  @override
  Future<DocumentMediaBytes> media(Uri url, {required String requestId}) async {
    if (!url.isAbsolute || !const {'http', 'https'}.contains(url.scheme)) {
      throw ArgumentError.value(url, 'url', 'needs an absolute http(s) URL');
    }
    final wire = await _map('media', {
      'url': url.toString(),
      'requestId': requestId,
    });
    return DocumentMediaBytes(
      wire['bytes'] as Uint8List,
      wire['mimeType'] as String? ?? '',
    );
  }

  @override
  Future<void> cancelMedia(String requestId) =>
      channel.invokeMethod<void>('mediaCancel', {'requestId': requestId});

  @override
  Future<void> close(DocumentScriptSession session) =>
      channel.invokeMethod<void>('close', _session(session));

  @override
  Future<void> closeAll() => channel.invokeMethod<void>('closeAll');
}

/// An in-memory [ScriptsPlatform] for tests: it keeps storage and cookies per
/// session, as Kotlin does, and records every call.
class FakeScriptsPlatform implements ScriptsPlatform {
  FakeScriptsPlatform({this.supported = true, this.mediaBytes = const {}});

  final bool supported;

  /// The bytes [media] answers per URL.
  final Map<Uri, DocumentMediaBytes> mediaBytes;
  final calls = <String>[];
  final mediaRequests = <Uri>[];
  final _sessions =
      <
        int,
        ({
          String owner,
          Map<String, String> local,
          Map<String, String> session,
          List<String> cookies,
        })
      >{};
  var _next = 1;

  int get openSessions => _sessions.length;

  /// As Kotlin: a closed session fails with `SCRIPT_CLOSED`, a wrong owner
  /// with `SCRIPT_OWNER`.
  ({
    String owner,
    Map<String, String> local,
    Map<String, String> session,
    List<String> cookies,
  })
  _state(DocumentScriptSession session) {
    final state =
        _sessions[session.id] ??
        (throw PlatformException(code: ScriptsError.closed));
    if (state.owner != session.owner) {
      throw PlatformException(code: ScriptsError.owner);
    }
    return state;
  }

  @override
  Future<DocumentScriptCapabilities> capabilities() async {
    calls.add('capabilities');
    return DocumentScriptCapabilities(supported: supported);
  }

  @override
  Future<DocumentScriptSession> open() async {
    calls.add('open');
    if (!supported) throw PlatformException(code: ScriptsError.unsupported);
    final id = _next++;
    final owner = _newOwner();
    _sessions[id] = (owner: owner, local: {}, session: {}, cookies: []);
    return DocumentScriptSession(id, owner);
  }

  @override
  Future<void> loadRuntime(DocumentScriptSession session) async {
    calls.add('runtime');
    _state(session);
  }

  @override
  Future<String> canvasText(
    DocumentScriptSession session, {
    required List<String> families,
    required String sample,
  }) async {
    calls.add('canvasText');
    _state(session);
    return '{"ok":true}';
  }

  @override
  Future<String> evaluate(DocumentScriptSession session, String source) async {
    calls.add('evaluate');
    _state(session);
    return '';
  }

  @override
  Future<DocumentStorageState> storage(
    DocumentScriptSession session, [
    List<DocumentStorageOperation> operations = const [],
  ]) async {
    calls.add('storage');
    final state = _state(session);
    for (final operation in operations) {
      final area = operation.area == 'local' ? state.local : state.session;
      switch (operation.op) {
        case 'set':
          area[operation.key!] = operation.value!;
        case 'remove':
          area.remove(operation.key);
        case 'clear':
          area.clear();
      }
    }
    return DocumentStorageState(
      local: Map.of(state.local),
      session: Map.of(state.session),
    );
  }

  @override
  Future<String> cookies(
    DocumentScriptSession session, [
    List<String> writes = const [],
  ]) async {
    calls.add('cookies');
    final state = _state(session);
    state.cookies.addAll(writes.map((line) => line.split(';').first.trim()));
    return state.cookies.join('; ');
  }

  @override
  Future<DocumentResourceResponse> resource(
    DocumentScriptSession session,
    DocumentResourceRequest request,
  ) async {
    calls.add('resource');
    _state(session);
    throw PlatformException(code: ScriptsError.resource);
  }

  @override
  Future<void> cancelResource(
    DocumentScriptSession session,
    String requestId,
  ) async => calls.add('resourceCancel');

  @override
  Future<DocumentMediaBytes> media(Uri url, {required String requestId}) async {
    calls.add('media');
    mediaRequests.add(url);
    return mediaBytes[url] ??
        (throw PlatformException(code: ScriptsError.resource));
  }

  @override
  Future<void> cancelMedia(String requestId) async => calls.add('mediaCancel');

  @override
  Future<void> close(DocumentScriptSession session) async {
    calls.add('close');
    _state(session);
    _sessions.remove(session.id);
  }

  @override
  Future<void> closeAll() async {
    calls.add('closeAll');
    _sessions.clear();
  }
}
