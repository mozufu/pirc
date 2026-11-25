import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/connection.dart';
import '../connection/data.dart';
import '../format.dart';

enum AccessPhase { none, requesting, waiting, granted, denied, expired, failed }

@immutable
class AccessState {
  const AccessState({
    this.phase = AccessPhase.none,
    this.request,
    this.address,
    this.capabilities = const [],
    this.expiresAt,
    this.error,
  });

  final AccessPhase phase;
  final ManagementRequest? request;

  /// The address to open in a browser to approve.
  final Uri? address;

  /// What the current grant (or request) covers.
  final List<String> capabilities;

  /// When the grant (or the request) expires, local time.
  final DateTime? expiresAt;
  final String? error;

  bool covers(String capability) =>
      phase == AccessPhase.granted && capabilities.contains(capability);
}

/// How often a waiting request is read; tests shorten it.
final accessPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 2),
);

final managementAccessProvider =
    NotifierProvider<ManagementAccess, AccessState>(ManagementAccess.new);

/// A paired app's short-lived management grant: create a request with a
/// SHA-256 challenge, show the address to open in a browser, read the
/// request until it is decided, claim it with the verifier. The grant is
/// kept in memory only and dropped when it expires, when the user unpairs
/// (the connection clears it) and when the app stops.
class ManagementAccess extends Notifier<AccessState> {
  String? _verifier;
  Timer? _poll;
  Timer? _expiry;

  @override
  AccessState build() {
    ref.onDispose(_stopTimers);
    // The connection drops the grant on unpair or a new pairing.
    ref.listen(managementGrantProvider, (_, grant) {
      if (grant == null && state.phase == AccessPhase.granted) {
        _expiry?.cancel();
        state = const AccessState();
      }
    });
    return const AccessState();
  }

  void _stopTimers() {
    _poll?.cancel();
    _expiry?.cancel();
  }

  static String newVerifier() {
    final random = Random.secure();
    return base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static String challengeFor(String verifier) =>
      sha256.convert(utf8.encode(verifier)).toString();

  /// Local time for a Gateway time, using the reply's `serverNow`.
  DateTime _local(int at, int serverNow) {
    final now = ref.read(clockProvider)();
    return now.add(Duration(milliseconds: at - serverNow));
  }

  /// Asks for [capabilities] (at most two); replaces a pending request.
  Future<void> request(List<String> capabilities) async {
    final api = ref.read(apiProvider);
    final gateway = ref.read(connectionProvider).connection?.gateway;
    if (api == null || gateway == null) return;
    _stopTimers();
    final verifier = newVerifier();
    state = AccessState(
      phase: AccessPhase.requesting,
      capabilities: capabilities,
    );
    try {
      final created = await ManagementApi(api).create(
        challenge: challengeFor(verifier),
        capabilities: capabilities,
        replace: true,
      );
      _verifier = verifier;
      state = AccessState(
        phase: AccessPhase.waiting,
        request: created,
        address: gateway.resolve(created.verificationPath ?? '/'),
        capabilities: created.capabilities,
        expiresAt: _local(created.expiresAt, created.serverNow),
      );
      _poll = Timer.periodic(ref.read(accessPollIntervalProvider), (_) {
        unawaited(_check());
      });
    } on PircException catch (error) {
      if (!ref.read(connectionProvider.notifier).report(error)) {
        state = AccessState(phase: AccessPhase.failed, error: error.message);
      }
    }
  }

  bool _checking = false;

  Future<void> _check() async {
    final api = ref.read(apiProvider);
    final request = state.request;
    final verifier = _verifier;
    if (_checking || api == null || request == null || verifier == null) return;
    _checking = true;
    try {
      final current = await ManagementApi(api).view(request.id);
      switch (current.status) {
        case 'approved':
          _poll?.cancel();
          final grant = await ManagementApi(api).claim(request.id, verifier);
          _verifier = null;
          ref.read(managementGrantProvider.notifier).set(grant.token);
          final expires = _local(grant.expiresAt, grant.serverNow);
          state = AccessState(
            phase: AccessPhase.granted,
            capabilities: grant.capabilities,
            expiresAt: expires,
          );
          _expiry?.cancel();
          _expiry = Timer(
            expires.difference(ref.read(clockProvider)()),
            _expire,
          );
        case 'denied':
          _end(AccessPhase.denied);
        case 'expired' || 'revoked' || 'claimed':
          _end(AccessPhase.expired);
      }
    } on ApiError catch (error) {
      if (error.status == 404) _end(AccessPhase.expired);
    } on PircException {
      // Try again on the next tick.
    } finally {
      _checking = false;
    }
  }

  void _end(AccessPhase phase) {
    _poll?.cancel();
    _verifier = null;
    state = AccessState(phase: phase, capabilities: state.capabilities);
  }

  void _expire() {
    ref.read(managementGrantProvider.notifier).set(null);
    state = const AccessState(phase: AccessPhase.expired);
  }

  /// Stops waiting and cancels the request.
  Future<void> cancel() async {
    final api = ref.read(apiProvider);
    final request = state.request;
    _end(AccessPhase.none);
    if (api != null && request != null) {
      try {
        await ManagementApi(api).cancel(request.id);
      } on PircException {
        // It expires by itself.
      }
    }
  }
}
