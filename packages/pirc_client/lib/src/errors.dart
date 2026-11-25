import 'models/binding.dart';

/// Base of every failure this package reports.
sealed class PircException implements Exception {
  const PircException(this.message);
  final String message;
}

/// The gateway answered with an error status.
class ApiError extends PircException {
  const ApiError(this.status, this.code, String message, {this.details})
    : super(message);

  final int status;
  final String code;
  final Object? details;

  @override
  String toString() => 'ApiError($status, $code): $message';
}

/// 426 `client_upgrade_required`: this build is too old for the gateway.
class ClientUpgradeRequired extends ApiError {
  const ClientUpgradeRequired(String message, {Object? details})
    : super(426, 'client_upgrade_required', message, details: details);
}

/// 415 `request_shape_required`: a state-changing request lacked
/// `X-Pirc-Request: 1` (a client bug, never retried).
class RequestShapeRequired extends ApiError {
  const RequestShapeRequired(String message, {Object? details})
    : super(415, 'request_shape_required', message, details: details);
}

/// 401 (or event socket close 4401): the device must pair again.
class PairingRequired extends ApiError {
  const PairingRequired(String message, {String code = 'unauthenticated'})
    : super(401, code, message);
}

/// 409 `stale_environment`: the session's binding moved on; [binding] is the
/// current one from `details.binding`.
class StaleEnvironment extends ApiError {
  const StaleEnvironment(String message, {this.binding, Object? details})
    : super(409, 'stale_environment', message, details: details);
  final ExpectedBinding? binding;
}

/// 409 `lost_control`: another client holds the control lease now.
class LostControl extends ApiError {
  const LostControl(String message, {Object? details})
    : super(409, 'lost_control', message, details: details);
}

/// 409 `account_changed`: `x-pirc-account` no longer matches the signed-in user.
class AccountChanged extends ApiError {
  const AccountChanged(String message, {Object? details})
    : super(409, 'account_changed', message, details: details);
}

/// The request did not complete: no connection, a dropped connection or a
/// timeout. Whether the gateway acted on it is unknown.
class TransportException extends PircException {
  const TransportException(super.message, {this.cause});
  final Object? cause;

  @override
  String toString() => 'TransportException: $message';
}

/// No reply within the request's time limit.
class RequestTimeout extends TransportException {
  const RequestTimeout(super.message);
}

/// The event socket upgrade was answered with an HTTP status instead of 101.
class EventSocketRefused extends TransportException {
  const EventSocketRefused(this.status, String message) : super(message);
  final int? status;
}
