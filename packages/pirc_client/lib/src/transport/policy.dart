/// Request rules both adapters follow, and the mapping of error replies to
/// typed exceptions.
library;

import '../../pirc_client.dart' show clientApp, apiVersion, clientHeaderValue;
import '../errors.dart';
import '../models/api_error.dart';
import '../models/binding.dart';
import 'transport.dart';

const clientHeader = 'X-Pirc-Client';
const requestHeader = 'X-Pirc-Request';
const accountHeader = 'x-pirc-account';
const managementHeader = 'x-pirc-management';

/// Whether [path] is a route that needs the management grant: the same rule
/// the Gateway uses (`/api/devices`, `/api/providers`, `/api/provider-auth`,
/// exactly or followed by `/`, raw or percent-decoded).
bool isManagementPath(String path) {
  String decoded;
  try {
    decoded = Uri.decodeComponent(path);
  } on ArgumentError {
    decoded = path;
  }
  return [path, decoded].any(
    (candidate) =>
        const ['/api/devices', '/api/providers', '/api/provider-auth'].any((
          prefix,
        ) {
          if (!candidate.startsWith(prefix)) return false;
          final rest = candidate.substring(prefix.length);
          return rest.isEmpty || rest.startsWith('/');
        }),
  );
}

/// Headers every request carries (no credentials; adapters add those).
Map<String, String> policyHeaders(ApiRequest request, TransportConfig config) {
  final account = config.account?.call();
  // The grant goes only to the routes that need it, never anywhere else.
  final grant = isManagementPath(request.path)
      ? config.managementGrant?.call()
      : null;
  return {
    clientHeader: clientHeaderValue(),
    if (request.isStateChanging) requestHeader: '1',
    if (grant != null && grant.isNotEmpty) managementHeader: grant,
    if (account != null && account.isNotEmpty)
      accountHeader: Uri.encodeComponent(account),
    if (request.json != null) 'Content-Type': 'application/json',
    if (request.bytes != null)
      'Content-Type': request.contentType ?? 'application/octet-stream',
    'Accept': 'application/json',
  };
}

/// Headers for the event socket upgrade (where the platform allows headers).
Map<String, String> socketHeaders(TransportConfig config) {
  final account = config.account?.call();
  return {
    clientHeader: clientHeaderValue(),
    if (account != null && account.isNotEmpty)
      accountHeader: Uri.encodeComponent(account),
  };
}

/// The request URL: [ApiRequest.path] and [ApiRequest.query] on [base].
Uri requestUri(Uri base, ApiRequest request) {
  final resolved = base.resolve(request.path);
  return request.query.isEmpty
      ? resolved
      : resolved.replace(
          queryParameters: {...resolved.queryParameters, ...request.query},
        );
}

/// The event socket URL for [target] on [base]: `ws`/`wss`. Browsers cannot
/// set headers on a WebSocket, so [clientQuery] adds `client=pirc-app%2F2`.
Uri eventSocketUri(Uri base, Uri target, {bool clientQuery = false}) {
  final resolved = base.resolveUri(target);
  final scheme = switch (resolved.scheme) {
    'https' || 'wss' => 'wss',
    _ => 'ws',
  };
  return resolved.replace(
    scheme: scheme,
    queryParameters: {
      ...resolved.queryParameters,
      if (clientQuery) 'client': '$clientApp/$apiVersion',
    },
  );
}

/// The typed error for a non-2xx [response]; null for 2xx.
ApiError? errorFor(ApiResponse response) {
  final status = response.status;
  if (status >= 200 && status < 300) return null;
  final body = ErrorBody.fromJson(response.json());
  final code = body?.code ?? '';
  final message = body?.message ?? 'Request failed ($status)';
  final details = body?.details;
  if (status >= 300 && status < 400) {
    return ApiError(
      status,
      'redirect_refused',
      'The gateway answered with a redirect; it was not followed.',
    );
  }
  if (status == 426 || code == 'client_upgrade_required') {
    return ClientUpgradeRequired(message, details: details);
  }
  if (status == 415 || code == 'request_shape_required') {
    return RequestShapeRequired(message, details: details);
  }
  if (status == 401) {
    return PairingRequired(
      message,
      code: code.isEmpty ? 'unauthenticated' : code,
    );
  }
  if (status == 409) {
    switch (code) {
      case 'stale_environment':
        final binding = details is Map ? details['binding'] : null;
        return StaleEnvironment(
          message,
          binding: ExpectedBinding.maybe(binding),
          details: details,
        );
      case 'lost_control':
        return LostControl(message, details: details);
      case 'account_changed':
        return AccountChanged(message, details: details);
      case 'environment_required':
        return EnvironmentRequired(message, details: details);
      case 'taken_over':
        return TakenOver(message, details: details);
    }
  }
  return ApiError(
    status,
    code.isEmpty ? 'http_$status' : code,
    message,
    details: details,
  );
}

/// Throws [errorFor] of [response], if any.
ApiResponse checked(ApiResponse response) {
  final error = errorFor(response);
  if (error != null) throw error;
  return response;
}
