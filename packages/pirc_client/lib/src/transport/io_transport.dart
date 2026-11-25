/// The `dart:io` adapter (Android, macOS, tests): bearer token, redirects
/// never followed, WebSocket with headers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../errors.dart';
import 'policy.dart';
import 'sha1.dart';
import 'transport.dart';

/// Builds the platform transport (selected by `create_transport.dart`).
Transport createPlatformTransport(
  TransportConfig config, {
  TokenStore? tokens,
}) => IoTransport(config, tokens: tokens ?? const StaticTokenStore(null));

class IoTransport implements Transport {
  IoTransport(this.config, {required this.tokens, HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient() {
    _client = IOClient(_httpClient);
  }

  @override
  final TransportConfig config;
  final TokenStore tokens;
  final HttpClient _httpClient;
  late final IOClient _client;

  Future<Map<String, String>> _authorization() async {
    final token = await tokens.read();
    return token == null || token.isEmpty
        ? const {}
        : {'Authorization': 'Bearer $token'};
  }

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    final outgoing =
        http.Request(request.method, requestUri(config.baseUri, request))
          // Credentials never cross origins: a redirect comes back as a reply.
          ..followRedirects = false
          ..headers.addAll(policyHeaders(request, config))
          ..headers.addAll(await _authorization());
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
    } on IOException catch (error) {
      throw TransportException(error.toString(), cause: error);
    }
  }

  @override
  Future<EventSocket> connectEvents(Uri target) async {
    final uri = eventSocketUri(config.baseUri, target);
    final headers = {...socketHeaders(config), ...await _authorization()};
    try {
      final socket = await _upgrade(uri, headers);
      return _IoEventSocket(socket);
    } on IOException catch (error) {
      throw TransportException(error.toString(), cause: error);
    }
  }

  /// `WebSocket.connect` follows redirects (carrying headers to subdomains
  /// and other ports), so the handshake is done here with redirects off.
  Future<WebSocket> _upgrade(Uri uri, Map<String, String> headers) async {
    final random = Random.secure();
    final key = base64Encode(List.generate(16, (_) => random.nextInt(256)));
    final request = await _httpClient.openUrl(
      'GET',
      uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http'),
    );
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Key', key)
      ..set('Sec-WebSocket-Version', '13')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close();
    final upgraded =
        response.statusCode == HttpStatus.switchingProtocols &&
        (response.headers[HttpHeaders.connectionHeader] ?? const []).any(
          (value) => value.toLowerCase() == 'upgrade',
        ) &&
        response.headers.value(HttpHeaders.upgradeHeader)?.toLowerCase() ==
            'websocket';
    if (!upgraded) {
      await response.drain<void>().catchError((_) {});
      throw EventSocketRefused(
        response.statusCode,
        'Event socket refused (${response.statusCode})',
      );
    }
    final expected = base64Encode(
      sha1(ascii.encode('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11')),
    );
    if (response.headers.value('Sec-WebSocket-Accept') != expected) {
      (await response.detachSocket()).destroy();
      throw const EventSocketRefused(null, 'Invalid WebSocket handshake');
    }
    return WebSocket.fromUpgradedSocket(
      await response.detachSocket(),
      serverSide: false,
    );
  }

  @override
  void close() => _client.close();
}

class _IoEventSocket implements EventSocket {
  _IoEventSocket(this._socket);

  final WebSocket _socket;

  @override
  late final Stream<Object?> messages = _socket
      .where((frame) => frame is String)
      .map((frame) => jsonDecode(frame as String))
      .handleError((Object _) {
        unawaited(_socket.close(1003, 'Invalid event'));
      }, test: (error) => error is FormatException);

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;

  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);
}
