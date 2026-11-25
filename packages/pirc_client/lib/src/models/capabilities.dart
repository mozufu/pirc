import 'package:meta/meta.dart';

import '../json.dart';

/// One optional gateway feature (`features.<name>`).
@immutable
class Feature {
  const Feature({
    this.supported = false,
    this.enabled = false,
    this.version,
    this.extra = const {},
  });

  factory Feature.fromJson(Object? json) {
    final map = object(json) ?? const {};
    return Feature(
      supported: map['supported'] == true,
      enabled: map['enabled'] == true,
      version: number(map['version']),
      extra: {
        for (final entry in map.entries)
          if (!const {'supported', 'enabled', 'version'}.contains(entry.key))
            entry.key: entry.value,
      },
    );
  }

  final bool supported;
  final bool enabled;
  final int? version;

  /// Feature-specific fields, e.g. `attachmentRetentionDays` for first send.
  final Map<String, Object?> extra;

  bool get usable => supported && enabled;
}

/// `GET /api/capabilities`.
@immutable
class Capabilities {
  const Capabilities({
    required this.apiVersion,
    this.serverVersion,
    this.accountUser,
    this.features = const {},
  });

  factory Capabilities.fromJson(Object? json) => Capabilities(
    apiVersion: number(field(json, 'apiVersion')) ?? 0,
    serverVersion: text(field(field(json, 'server'), 'version')),
    accountUser: str(field(field(json, 'account'), 'user')),
    features: {
      for (final entry in (object(field(json, 'features')) ?? const {}).entries)
        entry.key: Feature.fromJson(entry.value),
    },
  );

  final int apiVersion;
  final String? serverVersion;

  /// The signed-in account; sent back as `x-pirc-account`.
  final String? accountUser;
  final Map<String, Feature> features;

  Feature get firstSend => features['firstSend'] ?? const Feature();
  Feature get environmentSwitching =>
      features['environmentSwitching'] ?? const Feature();
}
