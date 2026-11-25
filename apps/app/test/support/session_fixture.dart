import 'dart:convert';
import 'dart:io';

import 'harness.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('../../fixtures/timeline/$name').readAsStringSync())
        as Map<String, Object?>;

/// A Gateway serving one session from a timeline fixture, with a lease
/// holder the test sets.
class FixtureSession {
  FixtureSession(this.name) : fixture = _fixture(name) {
    snapshot = fixture['snapshot']! as Map<String, Object?>;
    id = (snapshot['session']! as Map)['id'] as String;
  }

  final String name;
  final Map<String, Object?> fixture;
  late Map<String, Object?> snapshot;
  late final String id;

  /// The lease the control route reports; null when nobody holds it.
  Map<String, Object?>? lease;
  int generation = 0;
  bool heartbeatLost = false;

  List<Object?> get events => fixture['events']! as List<Object?>;

  FakeGateway install([FakeGateway? into]) {
    final gateway = into ?? FakeGateway();
    final base = '/api/sessions/$id';
    gateway.json['GET /api/sessions'] = (_) => {
      'sessions': [snapshot['session']],
    };
    gateway.json['GET $base/snapshot'] = (_) => snapshot;
    gateway.json['GET $base/control'] = (_) => {'lease': lease};
    gateway.json['POST $base/control/acquire'] = (request) {
      final body = request.json! as Map;
      if (lease != null &&
          lease!['clientId'] != body['clientId'] &&
          body['force'] != true) {
        return apiError(409, 'lost_control', 'Another client has control');
      }
      lease = {
        'clientId': body['clientId'],
        'generation': ++generation,
        'expiresAt': 0,
      };
      return {'lease': lease};
    };
    gateway.json['POST $base/control/heartbeat'] = (request) => heartbeatLost
        ? apiError(409, 'lost_control', 'Another client has control')
        : {'lease': lease};
    gateway.json['POST $base/control/release'] = (_) => {'released': true};
    return gateway;
  }
}
