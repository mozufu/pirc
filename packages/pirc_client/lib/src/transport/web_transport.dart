/// The browser adapter: forward-auth cookie on the same origin (no
/// Authorization header), browser WebSocket (no custom headers, so the client
/// version goes in the query).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../errors.dart';
import 'policy.dart';
import 'transport.dart';

/// Builds the platform transport (selected by `create_transport.dart`).
/// [tokens] is ignored: the browser sends the forward-auth cookie.
Transport createPlatformTransport(
  TransportConfig config, {
  TokenStore? tokens,
}) => WebTransport(config);

class WebTransport implements Transport {
  WebTransport(this.config);

  @override
  final TransportConfig config;
  final BrowserClient _client = BrowserClient()..withCredentials = true;

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    final outgoing =
        http.Request(request.method, requestUri(config.baseUri, request))
          // fetch(redirect: 'error'): a redirect fails instead of being followed.
          ..followRedirects = false
          ..headers.addAll(policyHeaders(request, config));
    if (request.json != null) {
      outgoing.body = jsonEncode(request.json);
    } else if (request.bytes != null) {
      outgoing.bodyBytes = request.bytes!;
    }
    try {
      final reply = await _client.send(outgoing);
      final body = await reply.stream.toBytes();
      return ApiResponse(reply.statusCode, body, headers: reply.headers);
    } on http.ClientException catch (error) {
      throw TransportException(error.message, cause: error);
    }
  }

  @override
  Future<EventSocket> connectEvents(Uri target) async {
    final uri = eventSocketUri(config.baseUri, target, clientQuery: true);
    final socket = _WebEventSocket(web.WebSocket(uri.toString()));
    await socket.opened;
    return socket;
  }

  @override
  void close() => _client.close();
}

class _WebEventSocket implements EventSocket {
  _WebEventSocket(this._socket) {
    _subscriptions = [
      web.EventStreamProviders.openEvent.forTarget(_socket).listen((_) {
        if (!_opened.isCompleted) _opened.complete();
      }),
      web.EventStreamProviders.messageEvent
          .forTarget(_socket)
          .listen(_onMessage),
      web.EventStreamProviders.closeEvent.forTarget(_socket).listen(_onClose),
    ];
  }

  final web.WebSocket _socket;
  final _opened = Completer<void>();
  final _controller = StreamController<Object?>();
  late final List<StreamSubscription<web.Event>> _subscriptions;
  int? _closeCode;
  String? _closeReason;

  Future<void> get opened => _opened.future;

  void _onMessage(web.MessageEvent event) {
    final data = event.data;
    if (!data.isA<JSString>()) return;
    try {
      _controller.add(jsonDecode((data as JSString).toDart));
    } on FormatException {
      _socket.close(1003, 'Invalid event');
    }
  }

  void _onClose(web.CloseEvent event) {
    _closeCode = event.code;
    _closeReason = event.reason;
    if (!_opened.isCompleted) {
      // Browsers hide the HTTP status of a refused upgrade.
      _opened.completeError(
        EventSocketRefused(null, 'Event socket closed (${event.code})'),
      );
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_controller.close());
  }

  @override
  Stream<Object?> get messages => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  Future<void> close([int? code, String? reason]) async {
    if (code != null) {
      _socket.close(code, reason ?? '');
    } else {
      _socket.close();
    }
  }

  @override
  void send(Object? message) {
    if (_socket.readyState == web.WebSocket.OPEN) {
      _socket.send(jsonEncode(message).toJS);
    }
  }
}
