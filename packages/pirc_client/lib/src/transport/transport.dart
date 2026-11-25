import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

/// One HTTP request to the gateway. [path] is absolute (`/api/...`) and is
/// resolved against the transport's base URI.
@immutable
class ApiRequest {
  const ApiRequest(
    this.method,
    this.path, {
    this.query = const {},
    this.json,
    this.bytes,
    this.contentType,
  }) : assert(json == null || bytes == null);

  const ApiRequest.get(String path, {Map<String, String> query = const {}})
    : this('GET', path, query: query);
  const ApiRequest.post(String path, {Object? json})
    : this('POST', path, json: json);
  const ApiRequest.delete(String path) : this('DELETE', path);
  const ApiRequest.putBytes(
    String path,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
  }) : this('PUT', path, bytes: bytes, contentType: contentType);

  final String method;
  final String path;
  final Map<String, String> query;

  /// A JSON body (encoded with `jsonEncode`).
  final Object? json;

  /// A raw body (attachments).
  final List<int>? bytes;
  final String? contentType;

  /// Everything except GET is state-changing and carries `X-Pirc-Request: 1`.
  bool get isStateChanging => method.toUpperCase() != 'GET';
}

/// The gateway's reply, whatever its status.
@immutable
class ApiResponse {
  const ApiResponse(this.status, this.body, {this.headers = const {}});

  final int status;

  /// Lower-case header names.
  final Map<String, String> headers;
  final List<int> body;

  bool get ok => status >= 200 && status < 300;

  /// The body as JSON; null when empty or not JSON.
  Object? json() {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(body, allowMalformed: true));
    } on FormatException {
      return null;
    }
  }
}

/// Where the device token comes from (Keystore, Keychain, memory).
abstract interface class TokenStore {
  /// The bearer token, or null when the device is not paired.
  FutureOr<String?> read();
}

/// A [TokenStore] holding one fixed token.
class StaticTokenStore implements TokenStore {
  const StaticTokenStore(this.token);
  final String? token;
  @override
  String? read() => token;
}

/// What both adapters share.
@immutable
class TransportConfig {
  const TransportConfig({required this.baseUri, this.account});

  /// The gateway origin (`https://pirc.example`); on the web, the page origin.
  final Uri baseUri;

  /// The signed-in account, sent as `x-pirc-account` when known.
  final String? Function()? account;
}

/// An open `/api/events` socket.
abstract interface class EventSocket {
  /// Decoded JSON frames; done when the socket closes.
  Stream<Object?> get messages;

  /// Set once [messages] is done.
  int? get closeCode;
  String? get closeReason;

  Future<void> close([int? code, String? reason]);
}

/// HTTP and the event socket, one implementation per platform.
abstract interface class Transport {
  TransportConfig get config;

  /// Sends one request and returns the reply whatever its status. Throws
  /// [TransportException] when no reply arrived.
  Future<ApiResponse> send(ApiRequest request);

  /// Opens the event socket at [target] (path and query, e.g.
  /// `/api/events?sessionId=…`). Throws [EventSocketRefused] when the
  /// upgrade is answered with an HTTP status.
  Future<EventSocket> connectEvents(Uri target);

  void close();
}
