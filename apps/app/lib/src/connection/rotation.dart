import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../format.dart';
import 'connection.dart';
import 'storage.dart';

/// Rotate once less than this much of the maximum window is left
/// (plans/roadmap.md M8 default B: a phone used once a week never pairs
/// again).
const rotateBefore = Duration(days: 23);

/// Warn once less than this much of the effective expiry is left.
const warnBefore = Duration(days: 3);

/// How long to wait before asking again after a rotation whose outcome is
/// unknown. Tests shorten it.
final rotationRetryDelayProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 30),
);

/// How long the Gateway keeps the old token after a rotation whose new
/// token was never used (`POST /api/device/rotate`); asking again with the
/// old token in that time replaces the lost token.
const rotationGrace = Duration(minutes: 5);

/// This device's record as last read, and whether the last rotation failed.
@immutable
class DeviceLifetime {
  const DeviceLifetime({this.device, this.rotationFailed = false});

  final DeviceSummary? device;
  final bool rotationFailed;
}

final deviceLifetimeProvider = NotifierProvider<TokenRotation, DeviceLifetime>(
  TokenRotation.new,
);

/// Whether [error] leaves the outcome of a rotation unknown: no reply, a
/// timeout, or a 5xx (a proxy may answer for a Gateway that rotated).
bool _outcomeUnknown(PircException error) =>
    error is TransportException || (error is ApiError && error.status >= 500);

/// Token rotation (A7, default B). When the app comes to the foreground (and
/// when it connects) it reads `GET /api/device`; with less than
/// [rotateBefore] of the maximum window left it asks for a new token, saves
/// it and only then sends it. One rotation runs at a time.
///
/// The Gateway writes the new windows before it replies, so after a lost
/// reply the record already shows 30 days although this app still holds the
/// old token, which dies [rotationGrace] later. So before each rotation the
/// app keeps its send time in [PrefKeys.rotationUnknownSince] (it holds no
/// secret, and survives the process being killed mid-request). While it is
/// set, the outcome is unknown: the app asks again with the old token on
/// each connect and each return to the foreground, whatever the record
/// says, and during the first [rotationGrace] also every
/// [rotationRetryDelayProvider]. It is cleared by a reply (the new token
/// saved, or a known refusal), by a record that still shows less than
/// [rotateBefore] (the Gateway did not rotate), or by the end of the
/// pairing. After the grace an old token that the Gateway did replace gets
/// a 401, which sends the app to pairing as any request would.
class TokenRotation extends Notifier<DeviceLifetime> {
  Future<void>? _running;
  Timer? _retry;

  @override
  DeviceLifetime build() {
    if (ref.watch(isWebProvider)) return const DeviceLifetime();
    final lifecycle = AppLifecycleListener(onResume: () => unawaited(check()));
    ref.onDispose(() {
      lifecycle.dispose();
      _retry?.cancel();
    });
    ref.listen(connectionProvider.select((s) => s.phase), (previous, phase) {
      if (phase == ConnectionPhase.online &&
          previous != ConnectionPhase.online) {
        unawaited(check());
      } else if (phase == ConnectionPhase.unpaired) {
        _retry?.cancel();
        unawaited(_setUnknownSince(null));
        state = const DeviceLifetime();
      }
    });
    return const DeviceLifetime();
  }

  /// Reads the device record and rotates when it is time. A call while one
  /// runs joins it.
  Future<void> check() =>
      _running ??= _check().whenComplete(() => _running = null);

  ApiClient? _api() {
    final status = ref.read(connectionProvider);
    return status.phase == ConnectionPhase.online
        ? status.connection?.api
        : null;
  }

  DateTime _now() => ref.read(clockProvider)();

  DateTime? _unknownSince() {
    final at = ref
        .read(sharedPreferencesProvider)
        .getInt(PrefKeys.rotationUnknownSince);
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  Future<void> _setUnknownSince(DateTime? at) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (at == null) {
      await prefs.remove(PrefKeys.rotationUnknownSince);
    } else {
      await prefs.setInt(
        PrefKeys.rotationUnknownSince,
        at.millisecondsSinceEpoch,
      );
    }
  }

  Future<void> _check() async {
    final api = _api();
    if (api == null) return;
    final unknown = _unknownSince() != null;
    DeviceSummary? device;
    try {
      device = await DeviceApi(api).read();
    } on PircException {
      // Offline or refused; a 401 already sends the app to pairing. With an
      // unknown outcome the app asks again anyway.
      if (!unknown) return;
    }
    if (!ref.mounted) return;
    if (device != null) {
      state = DeviceLifetime(
        device: device,
        rotationFailed: state.rotationFailed,
      );
      final left = DateTime.fromMillisecondsSinceEpoch(
        device.expiresAt,
      ).difference(_now());
      if (left < rotateBefore) {
        // Not rotated (or never needed): the record is right; this
        // rotation starts its own window.
        if (unknown) await _setUnknownSince(null);
      } else if (!unknown) {
        state = DeviceLifetime(device: device);
        return;
      }
      // Otherwise the record may show windows whose token never arrived.
    }
    await _rotate();
  }

  Future<void> _rotate() async {
    final connection = ref.read(connectionProvider.notifier);
    final api = _api();
    final previous = await connection.currentToken();
    if (api == null || previous == null || !ref.mounted) return;
    // Kept before the request: a process killed before the reply, or
    // between the reply and the Keystore write, still knows to ask again.
    // The first send time is kept; asking again does not extend the grace.
    final since = _unknownSince() ?? _now();
    if (_unknownSince() == null) await _setUnknownSince(since);
    if (!ref.mounted) return;
    try {
      final (device, token) = await DeviceApi(api).rotate();
      if (!ref.mounted) return;
      _retry?.cancel();
      if (await connection.replaceToken(token, previous: previous)) {
        await _setUnknownSince(null);
        if (ref.mounted) state = DeviceLifetime(device: device);
        return;
      }
      // Not saved. Only a pairing that really changed (the user unpaired
      // or paired again) makes the old token's question moot.
      final stored = await ref.read(secretStoreProvider).read(deviceTokenKey);
      if (stored != previous) await _setUnknownSince(null);
    } on PircException catch (error) {
      if (!ref.mounted) return;
      final unchanged =
          ref.read(connectionProvider).phase == ConnectionPhase.online &&
          await connection.currentToken() == previous;
      if (!ref.mounted) return;
      if (!_outcomeUnknown(error)) {
        // A known refusal: the Gateway did not rotate. A 401 already sends
        // the app to pairing, which clears the time too.
        await _setUnknownSince(null);
      } else if (unchanged) {
        // Asked again on the next connect or foreground; during the first
        // grace also on a timer, after it no timer: a Gateway answering
        // 5xx for long is not asked every 30 seconds.
        final left = rotationGrace - _now().difference(since);
        if (left > Duration.zero) {
          final delay = ref.read(rotationRetryDelayProvider);
          _retry?.cancel();
          _retry = Timer(delay < left ? delay : left, () => unawaited(check()));
        }
      }
      if (!ref.mounted) return;
      // Any other refusal keeps the token, which works until it expires.
      state = DeviceLifetime(device: state.device, rotationFailed: true);
    }
  }
}

/// When the pairing ends, once rotation failed and less than [warnBefore]
/// of the effective expiry (the earlier of the idle and maximum windows) is
/// left; null otherwise.
final pairingEndWarningProvider = Provider<DateTime?>((ref) {
  final lifetime = ref.watch(deviceLifetimeProvider);
  final device = lifetime.device;
  if (!lifetime.rotationFailed || device == null) return null;
  final ends = DateTime.fromMillisecondsSinceEpoch(device.effectiveExpiresAt);
  final left = ends.difference(ref.watch(clockProvider)());
  return left < warnBefore ? ends : null;
});
