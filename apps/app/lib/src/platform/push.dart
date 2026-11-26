import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where this phone stands with UnifiedPush.
enum PushState { off, connecting, on, failed }

/// An installed UnifiedPush distributor (ntfy, …).
@immutable
class PushDistributor {
  const PushDistributor(this.id, this.name);

  /// Its package name.
  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is PushDistributor && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

@immutable
class PushStatus {
  const PushStatus(
    this.state, {
    this.distributor,
    this.error,
    this.subscriptionId,
    this.timeZone,
  });

  static PushStatus fromMap(Object? value) {
    final map = value is Map ? value : const {};
    return PushStatus(
      PushState.values.asNameMap()[map['state']] ?? PushState.off,
      distributor: map['distributor'] as String?,
      error: map['error'] as String?,
      subscriptionId: map['subscriptionId'] as String?,
      timeZone: map['timeZone'] as String?,
    );
  }

  final PushState state;

  /// The chosen distributor's package.
  final String? distributor;

  /// Why registration failed; shown as it is.
  final String? error;

  /// This phone's push target at the Gateway, once it took the endpoint.
  final String? subscriptionId;

  /// The phone's IANA time zone.
  final String? timeZone;
}

/// This phone's UnifiedPush registration through the `org.mozufu.pirc/push`
/// channel (plans/roadmap.md M8 step 3), and where the background client
/// connects. Kotlin sends the endpoint to the Gateway itself: a distributor
/// can hand out a new one while the app is closed.
abstract interface class PushPlatform {
  Future<List<PushDistributor>> distributors();
  Future<PushStatus> status();

  /// The status whenever it changes (an endpoint arrives, a registration
  /// fails).
  Stream<PushStatus> get changes;

  Future<PushStatus> enable(String distributor);
  Future<PushStatus> disable();

  /// Where the background client connects: the Gateway and this app's
  /// client ID. Holds no secret; the token stays in the Keystore.
  Future<void> configure(Uri gateway, String clientId);

  /// The app unpairs: push stops and the background target goes. With
  /// [atGateway] (the user unpaired) it is called while the token is still
  /// stored, so the Gateway forgets the endpoint; without it (the Gateway
  /// refused the token) nothing is sent.
  Future<void> forget({bool atGateway = true});
}

class ChannelPush implements PushPlatform {
  ChannelPush();

  static const channel = MethodChannel('org.mozufu.pirc/push');

  StreamController<PushStatus>? _changes;

  @override
  Future<List<PushDistributor>> distributors() async {
    final list = await channel.invokeListMethod<Object?>('distributors') ?? [];
    return [
      for (final item in list.whereType<Map>())
        PushDistributor('${item['id']}', '${item['name'] ?? item['id']}'),
    ];
  }

  @override
  Future<PushStatus> status() async =>
      PushStatus.fromMap(await channel.invokeMethod<Object?>('status'));

  @override
  Stream<PushStatus> get changes {
    final changes = _changes ??= StreamController<PushStatus>.broadcast(
      onListen: () => channel.setMethodCallHandler((call) async {
        if (call.method == 'status') {
          _changes?.add(PushStatus.fromMap(call.arguments));
        }
      }),
      onCancel: () => channel.setMethodCallHandler(null),
    );
    return changes.stream;
  }

  @override
  Future<PushStatus> enable(String distributor) async => PushStatus.fromMap(
    await channel.invokeMethod<Object?>('enable', {'distributor': distributor}),
  );

  @override
  Future<PushStatus> disable() async =>
      PushStatus.fromMap(await channel.invokeMethod<Object?>('disable'));

  @override
  Future<void> configure(Uri gateway, String clientId) =>
      channel.invokeMethod<void>('configure', {
        'gateway': gateway.toString(),
        'clientId': clientId,
      });

  @override
  Future<void> forget({bool atGateway = true}) =>
      channel.invokeMethod<void>('forget', {'atGateway': atGateway});
}

/// For tests: [installed] distributors, a status that follows enable and
/// disable, and what was configured.
class FakePush implements PushPlatform {
  FakePush({
    this.installed = const [PushDistributor('io.heckel.ntfy', 'ntfy')],
    PushStatus current = const PushStatus(PushState.off, timeZone: 'UTC'),
    this.subscriptionId = 'push-phone',
  }) : _status = current;

  List<PushDistributor> installed;
  final String subscriptionId;
  PushStatus _status;
  final calls = <String>[];
  Uri? gateway;
  String? clientId;
  final _changes = StreamController<PushStatus>.broadcast();

  void set(PushStatus status) {
    _status = status;
    _changes.add(status);
  }

  @override
  Future<List<PushDistributor>> distributors() async => installed;

  @override
  Future<PushStatus> status() async => _status;

  @override
  Stream<PushStatus> get changes => _changes.stream;

  @override
  Future<PushStatus> enable(String distributor) async {
    calls.add('enable $distributor');
    set(
      PushStatus(
        PushState.on,
        distributor: distributor,
        subscriptionId: subscriptionId,
        timeZone: _status.timeZone,
      ),
    );
    return _status;
  }

  @override
  Future<PushStatus> disable() async {
    calls.add('disable');
    set(PushStatus(PushState.off, timeZone: _status.timeZone));
    return _status;
  }

  @override
  Future<void> configure(Uri gateway, String clientId) async {
    calls.add('configure');
    this.gateway = gateway;
    this.clientId = clientId;
  }

  @override
  Future<void> forget({bool atGateway = true}) async {
    calls.add(atGateway ? 'forget' : 'forget locally');
    gateway = null;
    clientId = null;
    set(PushStatus(PushState.off, timeZone: _status.timeZone));
  }
}

/// UnifiedPush on this platform: Android only.
final pushPlatformProvider = Provider<PushPlatform?>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? ChannelPush()
      : null,
);
