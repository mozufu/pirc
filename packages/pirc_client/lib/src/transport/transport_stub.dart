import 'transport.dart';

/// Neither `dart:io` nor `dart:js_interop` is available.
Transport createPlatformTransport(
  TransportConfig config, {
  TokenStore? tokens,
}) => throw UnsupportedError('No pirc transport for this platform');
