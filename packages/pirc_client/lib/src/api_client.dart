import 'dart:async';

import 'errors.dart';
import 'models/capabilities.dart';
import 'models/snapshot.dart';
import 'transport/policy.dart';
import 'transport/transport.dart';

/// JSON calls over a [Transport]: a time limit per request and typed errors.
class ApiClient {
  ApiClient(this.transport, {this.timeout = const Duration(seconds: 30)});

  final Transport transport;

  /// How long one request may take before it fails with [RequestTimeout].
  final Duration timeout;

  /// Sends [request] and returns the reply whatever its status.
  Future<ApiResponse> send(ApiRequest request, {Duration? timeout}) {
    final limit = timeout ?? this.timeout;
    return transport
        .send(request)
        .timeout(
          limit,
          onTimeout: () => throw RequestTimeout(
            '${request.method} ${request.path} took over $limit',
          ),
        );
  }

  /// Sends [request]; throws the typed [ApiError] for a non-2xx reply.
  Future<Object?> json(ApiRequest request, {Duration? timeout}) async =>
      checked(await send(request, timeout: timeout)).json();

  Future<Object?> get(String path, {Map<String, String> query = const {}}) =>
      json(ApiRequest.get(path, query: query));

  Future<Object?> post(String path, [Object? body]) =>
      json(ApiRequest.post(path, json: body ?? const <String, Object?>{}));

  /// `GET /api/capabilities`, read on connect.
  Future<Capabilities> capabilities() async =>
      Capabilities.fromJson(await get('/api/capabilities'));

  /// `GET /api/sessions/{id}/snapshot`.
  Future<SessionSnapshot> snapshot(String sessionId) async =>
      SessionSnapshot.fromJson(
        await get('/api/sessions/${Uri.encodeComponent(sessionId)}/snapshot'),
      );
}
