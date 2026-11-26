import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/app.dart';
import 'package:pirc_app/src/connection/connection.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/platform/links.dart';
import 'package:pirc_app/src/platform/media.dart';
import 'package:pirc_app/src/platform/scanner.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A JSON reply.
ApiResponse reply(int status, [Object? json]) => ApiResponse(
  status,
  json == null ? const [] : utf8.encode(jsonEncode(json)),
);

ApiResponse apiError(int status, String code, [String message = 'm']) =>
    reply(status, {
      'error': {'code': code, 'message': message},
    });

Map<String, Object?> capabilitiesJson({
  int apiVersion = 2,
  bool environmentSwitching = true,
}) => {
  'apiVersion': apiVersion,
  'server': {'version': '2.0.0-test'},
  'account': {'user': 'ana'},
  'features': {
    'firstSend': {
      'supported': true,
      'enabled': true,
      'version': 2,
      'attachmentRetentionDays': 7,
    },
    'pots': {'supported': true, 'enabled': true, 'version': 1},
    'environmentSwitching': {
      'supported': true,
      'enabled': environmentSwitching,
      'version': 1,
    },
  },
};

class FakeEventSocket implements EventSocket {
  FakeEventSocket(this.target);

  final Uri target;
  final _controller = StreamController<Object?>();
  int? _closeCode;
  bool closedByClient = false;
  final sent = <Object?>[];

  void push(Object? frame) => _controller.add(frame);

  void serverClose(int code) {
    _closeCode = code;
    unawaited(_controller.close());
  }

  @override
  Stream<Object?> get messages => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => null;

  @override
  void send(Object? message) => sent.add(message);

  @override
  Future<void> close([int? code, String? reason]) async {
    closedByClient = true;
    _closeCode ??= code ?? 1005;
    if (!_controller.isClosed) await _controller.close();
  }
}

typedef Route = FutureOr<ApiResponse?> Function(ApiRequest request);

/// A Gateway for widget tests: answers by method and path, records every
/// request and opens [FakeEventSocket]s.
class FakeGateway {
  FakeGateway({Map<String, Object?>? capabilities})
    : capabilities = capabilities ?? capabilitiesJson();

  Map<String, Object?> capabilities;

  /// `"GET /api/sessions"` → reply. Checked before [routes].
  final Map<String, Object? Function(ApiRequest request)> json = {};

  /// Fallback handlers, in order; the first non-null reply wins.
  final List<Route> routes = [];

  final requests = <ApiRequest>[];
  final sockets = <FakeEventSocket>[];
  final configs = <TransportConfig>[];
  final tokens = <TokenStore?>[];

  /// When set, connects fail with it.
  Object? connectError;

  /// Socket paths whose connects fail with the given error.
  final connectErrors = <String, Object>{};

  /// When set, every request fails with it.
  Object? sendError;

  Iterable<ApiRequest> sent(String method, String path) => requests.where(
    (request) => request.method == method && request.path == path,
  );

  FakeEventSocket? socket(String path) {
    for (final socket in sockets.reversed) {
      if (socket.target.path == path) return socket;
    }
    return null;
  }

  Transport transport(TransportConfig config, TokenStore? tokens) {
    configs.add(config);
    this.tokens.add(tokens);
    return _Transport(this, config);
  }

  Future<ApiResponse> answer(ApiRequest request) async {
    requests.add(request);
    if (sendError != null) throw sendError!;
    if (request.method == 'GET' && request.path == '/api/capabilities') {
      return reply(200, capabilities);
    }
    final handler = json['${request.method} ${request.path}'];
    if (handler != null) {
      final value = handler(request);
      return value is ApiResponse ? value : reply(200, value);
    }
    for (final route in routes) {
      final value = await route(request);
      if (value != null) return value;
    }
    return apiError(404, 'not_found', '${request.method} ${request.path}');
  }
}

class _Transport implements Transport {
  _Transport(this.gateway, this.config);

  final FakeGateway gateway;
  @override
  final TransportConfig config;

  @override
  Future<ApiResponse> send(ApiRequest request) => gateway.answer(request);

  @override
  Future<EventSocket> connectEvents(Uri target) async {
    if (gateway.connectError != null) throw gateway.connectError!;
    final refused = gateway.connectErrors[target.path];
    if (refused != null) throw refused;
    final socket = FakeEventSocket(target);
    gateway.sockets.add(socket);
    return socket;
  }

  @override
  void close() {}
}

/// Saved state for [pumpApp].
class Saved {
  Saved({Map<String, Object>? prefs, Map<String, String>? secrets})
    : prefs = prefs ?? {PrefKeys.gatewayUrl: 'https://gateway.test/'},
      secrets = MemorySecretStore(secrets ?? {deviceTokenKey: 'device-token'});

  /// Nothing saved: the device is not paired.
  Saved.unpaired() : prefs = {}, secrets = MemorySecretStore();

  final Map<String, Object> prefs;
  final MemorySecretStore secrets;
}

final _containers = <ProviderContainer>[];

/// Unmounts the app and disposes its providers, so their timers (lease
/// heartbeats, socket backoff) stop before the test ends.
Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (final container in _containers) {
    container.dispose();
  }
  _containers.clear();
  await tester.pump();
}

/// A widget test that disposes the app at its end ([disposeApp]).
void appTest(
  String description,
  Future<void> Function(WidgetTester tester) body, {
  Object? tags,
  bool? skip,
}) => testWidgets(
  description,
  (tester) async {
    await body(tester);
    await disposeApp(tester);
  },
  tags: tags,
  skip: skip,
);

/// Pumps the whole app at [width] against [gateway]. [reduceMotion] asks
/// for less motion, as the system setting does. [platformSecrets] keeps the
/// platform's secret store instead of [Saved.secrets]. [media] stands in for
/// the Android media channel ([FakeMediaPlayers]); without it the app has no
/// in-app player, as on Web and macOS. [scanner] and [links] stand in for
/// the scanner and links channels; without them the app has neither, as on
/// Web and macOS.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  required FakeGateway gateway,
  double width = 1300,
  double height = 900,
  String? location,
  Saved? saved,
  bool web = false,
  List overrides = const [],
  bool settle = true,
  bool reduceMotion = false,
  bool platformSecrets = false,
  MediaPlayers? media,
  Scanner? scanner,
  AppLinks? links,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  if (reduceMotion) {
    // Endless motion (a working pot's pulsing dots) stops, so the app
    // settles.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  final state = saved ?? Saved();
  SharedPreferences.setMockInitialValues(state.prefs);
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    retry: noRetry,
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      if (!platformSecrets)
        secretStoreProvider.overrideWithValue(state.secrets),
      transportFactoryProvider.overrideWithValue(gateway.transport),
      isWebProvider.overrideWithValue(web),
      mediaPlayersProvider.overrideWithValue(media),
      scannerProvider.overrideWithValue(scanner),
      appLinksProvider.overrideWithValue(links),
      webOriginProvider.overrideWithValue(Uri.parse('https://gateway.test/')),
      if (location != null) initialLocationProvider.overrideWithValue(location),
      ...overrides.cast(),
    ],
  );
  _containers.add(container);
  addTearDown(() {
    if (_containers.remove(container)) container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const PircApp()),
  );
  if (settle) await tester.pumpAndSettle();
  return container;
}
