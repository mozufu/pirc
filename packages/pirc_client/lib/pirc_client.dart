/// Gateway API models, transport, timeline reducer and repositories.
library;

/// The Gateway API version this client speaks (`GET /api/capabilities`).
const int apiVersion = 2;

/// The application name sent in `X-Pirc-Client`.
const String clientApp = 'pirc-app';

/// The `X-Pirc-Client` header value: `<app>/<apiVersion>`.
String clientHeaderValue({String app = clientApp, int version = apiVersion}) =>
    '$app/$version';
