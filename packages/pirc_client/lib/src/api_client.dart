import 'dart:async';

import '../pirc_client.dart' show apiVersion;
import 'errors.dart';
import 'models/capabilities.dart';
import 'models/snapshot.dart';
import 'transport/policy.dart';
import 'transport/transport.dart';

/// JSON calls over a [Transport]: a time limit per request and typed errors.
class ApiClient {
  ApiClient(
    this.transport, {
    this.timeout = const Duration(seconds: 30),
    this.onFatal,
  });

  final Transport transport;

  /// How long one request may take before it fails with [RequestTimeout].
  final Duration timeout;

  /// Called for every reply that means the whole connection is over: a 401
  /// ([PairingRequired]) or a 426 ([ClientUpgradeRequired]), whatever the
  /// route. The caller still gets the reply (or the thrown error).
  final void Function(PircException error)? onFatal;

  /// Sends [request] and returns the reply whatever its status.
  Future<ApiResponse> send(ApiRequest request, {Duration? timeout}) async {
    final limit = timeout ?? this.timeout;
    final response = await transport
        .send(request)
        .timeout(
          limit,
          onTimeout: () => throw RequestTimeout(
            '${request.method} ${request.path} took over $limit',
          ),
        );
    if (onFatal != null && !response.ok) {
      final error = errorFor(response);
      if (error is PairingRequired || error is ClientUpgradeRequired) {
        onFatal!(error!);
      }
    }
    return response;
  }

  /// Sends [request]; throws the typed [ApiError] for a non-2xx reply.
  Future<Object?> json(ApiRequest request, {Duration? timeout}) async =>
      checked(await send(request, timeout: timeout)).json();

  Future<Object?> get(String path, {Map<String, String> query = const {}}) =>
      json(ApiRequest.get(path, query: query));

  Future<Object?> post(String path, [Object? body]) =>
      json(ApiRequest.post(path, json: body ?? const <String, Object?>{}));

  Future<Object?> patch(String path, [Object? body]) =>
      json(ApiRequest.patch(path, json: body ?? const <String, Object?>{}));

  Future<Object?> put(String path, [Object? body]) =>
      json(ApiRequest.put(path, json: body ?? const <String, Object?>{}));

  Future<Object?> delete(String path, {Map<String, String> query = const {}}) =>
      json(ApiRequest.delete(path, query: query));

  /// `GET /api/capabilities`.
  Future<Capabilities> capabilities() async =>
      Capabilities.fromJson(await get('/api/capabilities'));

  /// The first call after connecting: reads the capability document and
  /// refuses a Gateway that speaks another API version. The Gateway answers
  /// an old client with 426 itself; this catches a client newer than it.
  Future<Capabilities> connect() async {
    final capabilities = await this.capabilities();
    if (capabilities.apiVersion != apiVersion) {
      throw ClientUpgradeRequired(
        'The Gateway speaks API version ${capabilities.apiVersion}; '
        'this app needs version $apiVersion.',
      );
    }
    return capabilities;
  }

  /// `GET /api/sessions/{id}/snapshot`.
  Future<SessionSnapshot> snapshot(String sessionId) async =>
      SessionSnapshot.fromJson(
        await get('/api/sessions/${Uri.encodeComponent(sessionId)}/snapshot'),
      );
}
