import 'transport.dart';
import 'transport_stub.dart'
    if (dart.library.js_interop) 'web_transport.dart'
    if (dart.library.io) 'io_transport.dart'
    as platform;

/// The transport for this platform: the browser adapter on the web (cookie,
/// [tokens] unused), the `dart:io` adapter elsewhere (bearer from [tokens]).
Transport createTransport(TransportConfig config, {TokenStore? tokens}) =>
    platform.createPlatformTransport(config, tokens: tokens);
