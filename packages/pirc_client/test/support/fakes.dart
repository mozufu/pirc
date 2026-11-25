import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:pirc_client/pirc_client.dart';

/// A reply for [FakeTransport]: JSON body with a status.
ApiResponse reply(int status, [Object? json]) => ApiResponse(
  status,
  json == null ? const [] : utf8.encode(jsonEncode(json)),
);

/// An [EventSocket] the test drives.
class FakeEventSocket implements EventSocket {
  final _controller = StreamController<Object?>();
  int? _closeCode;
  String? _closeReason;
  bool closedByClient = false;

  void push(Object? frame) => _controller.add(frame);

  /// The server closes the socket with [code].
  void serverClose(int code, [String reason = '']) {
    _closeCode = code;
    _closeReason = reason;
    unawaited(_controller.close());
  }

  @override
  Stream<Object?> get messages => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  final sent = <Object?>[];

  @override
  void send(Object? message) => sent.add(message);

  @override
  Future<void> close([int? code, String? reason]) async {
    closedByClient = true;
    _closeCode ??= code ?? 1005;
    _closeReason ??= reason;
    if (!_controller.isClosed) await _controller.close();
  }
}

/// Records every request and socket target; answers through [onSend] and
/// [onConnect].
class FakeTransport implements Transport {
  FakeTransport({this.onSend, this.onConnect});

  Future<ApiResponse> Function(ApiRequest request)? onSend;
  Future<EventSocket> Function(Uri target)? onConnect;

  final requests = <ApiRequest>[];
  final connects = <Uri>[];

  @override
  TransportConfig get config =>
      TransportConfig(baseUri: Uri.parse('https://gateway.test'));

  @override
  Future<ApiResponse> send(ApiRequest request) {
    requests.add(request);
    return onSend!(request);
  }

  @override
  Future<EventSocket> connectEvents(Uri target) {
    connects.add(target);
    return onConnect!(target);
  }

  @override
  void close() {}
}

/// A [Random] with fixed jitter.
class FixedRandom implements Random {
  FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

const binding = ExpectedBinding(
  membership: BindingMembership(revision: 3, legacyWorkspaceId: 'm5pro:pirc'),
  execution: BindingExecution(
    generation: 7,
    workspaceId: 'm5pro:pirc',
    modeId: 'default',
  ),
);
