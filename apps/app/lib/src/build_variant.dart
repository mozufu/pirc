import 'package:flutter/services.dart' show appFlavor;

/// Which Android build this is (plans/client.md, Embedded Tailscale).
///
/// The Gradle flavor (`--flavor standard|tailscale`) and the Dart define
/// (`--dart-define=PIRC_TAILSCALE=true|false`) are chosen together. Web and
/// desktop builds have no flavor and only the standard variant.
enum BuildVariant { standard, tailscale }

const bool _tailscaleDefine = bool.fromEnvironment('PIRC_TAILSCALE');

/// Resolves the variant and refuses a flavor that does not match the define.
BuildVariant resolveBuildVariant({
  String? flavor = appFlavor,
  bool tailscaleDefine = _tailscaleDefine,
}) {
  final expected = switch (flavor) {
    null || 'standard' => BuildVariant.standard,
    'tailscale' => BuildVariant.tailscale,
    _ => throw StateError('Unknown build flavor "$flavor".'),
  };
  final defined = tailscaleDefine
      ? BuildVariant.tailscale
      : BuildVariant.standard;
  if (expected != defined) {
    throw StateError(
      'Build flavor "${flavor ?? 'none'}" needs '
      '--dart-define=PIRC_TAILSCALE=${expected == BuildVariant.tailscale}.',
    );
  }
  return expected;
}
