import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../format.dart';
import '../platform/links.dart';
import '../settings/management_access.dart';
import 'connection.dart';
import 'pairing.dart';

enum PairingV2Phase {
  /// The user types the Gateway address and the device name.
  address,

  /// Creating the request.
  creating,

  /// Waiting for a browser to approve.
  waiting,

  /// Approved in a browser; the code shown there is needed.
  approved,

  /// Sending the code.
  claiming,

  /// The code was wrong; [PairingV2State.attemptsLeft] says how many tries
  /// are left (0: the request ended).
  wrongCode,
  denied,
  expired,

  /// Something else went wrong ([PairingV2State.problem]).
  failed,

  /// The token is saved; the app connects.
  paired,
}

enum PairingV2Problem {
  notAnAddress,
  badName,
  unreachable,
  appTooOld,

  /// 429: 20 requests are open on the Gateway.
  tooManyRequests,

  /// 409: the account already has 10 phones.
  tooManyPhones,
  failed,
}

@immutable
class PairingV2State {
  const PairingV2State(
    this.phase, {
    this.deviceName = '',
    this.approveAddress,
    this.expiresAt,
    this.attemptsLeft,
    this.problem,
    this.browserFailed = false,
  });

  final PairingV2Phase phase;
  final String deviceName;

  /// The approval page on the Gateway (`/?pair=<id>`).
  final Uri? approveAddress;

  /// When the request ends, local time.
  final DateTime? expiresAt;
  final int? attemptsLeft;
  final PairingV2Problem? problem;

  /// The browser could not be opened; the address is shown to open by hand.
  final bool browserFailed;

  /// A request is open: the code can be sent.
  bool get open =>
      phase == PairingV2Phase.waiting ||
      phase == PairingV2Phase.approved ||
      phase == PairingV2Phase.claiming ||
      (phase == PairingV2Phase.wrongCode && (attemptsLeft ?? 0) > 0);

  PairingV2State copyWith({
    PairingV2Phase? phase,
    int? attemptsLeft,
    PairingV2Problem? problem,
    bool? browserFailed,
  }) => PairingV2State(
    phase ?? this.phase,
    deviceName: deviceName,
    approveAddress: approveAddress,
    expiresAt: expiresAt,
    attemptsLeft: attemptsLeft ?? this.attemptsLeft,
    problem: problem,
    browserFailed: browserFailed ?? this.browserFailed,
  );
}

/// The approval page for [path] on [gateway], or null unless [path] is a
/// path of that Gateway: it starts with a single `/` and the address it
/// resolves to has the Gateway's origin.
Uri? approveAddressFor(Uri gateway, String path) {
  if (!path.startsWith('/') || path.startsWith('//') || path.contains('\\')) {
    return null;
  }
  final parsed = Uri.tryParse(path);
  if (parsed == null || parsed.hasScheme || parsed.hasAuthority) return null;
  final address = gateway.resolveUri(parsed);
  return address.origin == gateway.origin ? address : null;
}

/// How often a waiting request is read; tests shorten it.
final pairingV2PollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 2),
);

/// The platform name sent with a request.
final pairingPlatformProvider = Provider<String>(
  (ref) => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.iOS => 'ios',
    _ => 'other',
  },
);

final pairingV2Provider = NotifierProvider<PairingV2Controller, PairingV2State>(
  PairingV2Controller.new,
);

/// Pairing v2 (plans/roadmap.md M8 step 2): the app makes a random
/// verifier and sends only its SHA-256, a browser approves and shows a
/// 6-digit code, and the app claims its token with the verifier and the
/// code. The verifier stays in this object and leaves the app only in the
/// claim; neither it nor the code nor the token is logged.
///
/// The two routes need no identity and get no `Authorization` header: they
/// go through a transport of their own without a token.
class PairingV2Controller extends Notifier<PairingV2State> {
  Transport? _transport;
  ApiClient? _api;
  Uri? _gateway;
  String? _requestId;
  String? _verifier;
  Timer? _poll;
  Timer? _expiry;
  bool _polling = false;
  int _generation = 0;

  @override
  PairingV2State build() {
    ref.onDispose(_close);
    return const PairingV2State(PairingV2Phase.address);
  }

  void _close() {
    _generation++;
    _poll?.cancel();
    _expiry?.cancel();
    _transport?.close();
    _transport = null;
    _api = null;
    _requestId = null;
    _verifier = null;
  }

  DateTime _local(int at, int serverNow) =>
      ref.read(clockProvider)().add(Duration(milliseconds: at - serverNow));

  /// Creates a request on the Gateway at [address] for [deviceName], then
  /// opens the approval page in the browser.
  Future<void> start(String address, String deviceName) async {
    if (state.phase == PairingV2Phase.creating) return;
    final gateway = gatewayOrigin(address);
    final name = deviceName.trim();
    if (gateway == null) {
      state = const PairingV2State(
        PairingV2Phase.address,
        problem: PairingV2Problem.notAnAddress,
      );
      return;
    }
    if (name.isEmpty || name.length > 100) {
      state = const PairingV2State(
        PairingV2Phase.address,
        problem: PairingV2Problem.badName,
      );
      return;
    }
    _close();
    final generation = _generation;
    state = PairingV2State(PairingV2Phase.creating, deviceName: name);
    // No token store: these routes refuse an Authorization header.
    final transport = ref.read(transportFactoryProvider)(
      TransportConfig(baseUri: gateway),
      const StaticTokenStore(null),
    );
    final api = ApiClient(transport);
    _transport = transport;
    _api = api;
    _gateway = gateway;
    final verifier = ManagementAccess.newVerifier();
    try {
      final created = await PairingApi(api).create(
        deviceName: name,
        platform: ref.read(pairingPlatformProvider),
        challenge: ManagementAccess.challengeFor(verifier),
      );
      if (generation != _generation) return;
      final approveAddress = approveAddressFor(gateway, created.approvePath);
      if (approveAddress == null) {
        // Only a page of this Gateway is opened.
        _close();
        state = PairingV2State(
          PairingV2Phase.failed,
          deviceName: name,
          problem: PairingV2Problem.failed,
        );
        return;
      }
      _requestId = created.id;
      _verifier = verifier;
      final expiresAt = _local(created.expiresAt, created.serverNow);
      state = PairingV2State(
        PairingV2Phase.waiting,
        deviceName: name,
        approveAddress: approveAddress,
        expiresAt: expiresAt,
      );
      _poll = Timer.periodic(ref.read(pairingV2PollIntervalProvider), (_) {
        unawaited(_check());
      });
      _expiry = Timer(expiresAt.difference(ref.read(clockProvider)()), _expire);
      await openBrowser();
    } on PircException catch (error) {
      if (generation != _generation) return;
      _close();
      state = PairingV2State(
        PairingV2Phase.failed,
        deviceName: name,
        problem: switch (error) {
          ClientUpgradeRequired() => PairingV2Problem.appTooOld,
          ApiError(status: 429) => PairingV2Problem.tooManyRequests,
          TransportException() => PairingV2Problem.unreachable,
          _ => PairingV2Problem.failed,
        },
      );
    }
  }

  /// Opens the approval page again.
  Future<void> openBrowser() async {
    final address = state.approveAddress;
    final links = ref.read(appLinksProvider);
    if (address == null) return;
    if (links == null) {
      state = state.copyWith(browserFailed: true);
      return;
    }
    try {
      await links.openBrowser(address);
    } on Exception {
      state = state.copyWith(browserFailed: true);
    }
  }

  /// Reads whether the request was approved, without a code.
  Future<void> _check() async {
    final api = _api;
    final id = _requestId;
    final verifier = _verifier;
    if (_polling || api == null || id == null || verifier == null) return;
    if (state.phase != PairingV2Phase.waiting) return;
    final generation = _generation;
    _polling = true;
    try {
      final claim = await PairingApi(api).claim(id, verifier: verifier);
      if (generation != _generation) return;
      if (claim is PairingWaiting &&
          claim.approved &&
          state.phase == PairingV2Phase.waiting) {
        _poll?.cancel();
        state = state.copyWith(phase: PairingV2Phase.approved);
      }
    } on ApiError catch (error) {
      if (generation == _generation) _ended(error, afterCode: false);
    } on PircException {
      // Try again on the next tick.
    } finally {
      _polling = false;
    }
  }

  /// Claims the token with the 6-digit [code].
  Future<void> claim(String code) async {
    final api = _api;
    final id = _requestId;
    final verifier = _verifier;
    final gateway = _gateway;
    if (!state.open || state.phase == PairingV2Phase.claiming) return;
    if (api == null || id == null || verifier == null || gateway == null) {
      return;
    }
    final digits = code.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(digits)) return;
    final generation = _generation;
    final before = state;
    state = state.copyWith(phase: PairingV2Phase.claiming);
    try {
      final claim = await PairingApi(
        api,
      ).claim(id, verifier: verifier, code: digits);
      if (generation != _generation) return;
      switch (claim) {
        case PairingWaiting():
          // Not approved yet: the code cannot be checked.
          state = before.copyWith(phase: PairingV2Phase.waiting);
          _expireIfDue();
        case PairingClaimed(:final token) when token.isEmpty:
          _close();
          state = before.copyWith(
            phase: PairingV2Phase.failed,
            problem: PairingV2Problem.failed,
          );
        case PairingClaimed(:final token):
          await _save(generation, before, gateway, token);
      }
    } on ApiError catch (error) {
      if (generation != _generation) return;
      final left = PairingApi.attemptsLeft(error);
      if (left != null) {
        state = before.copyWith(
          phase: PairingV2Phase.wrongCode,
          attemptsLeft: left,
        );
        _expireIfDue();
      } else {
        state = before;
        // Only an approved request counts wrong codes.
        _ended(error, afterCode: before.phase != PairingV2Phase.waiting);
      }
    } on PircException catch (error) {
      if (generation != _generation) return;
      state = before.copyWith(
        problem: error is TransportException
            ? PairingV2Problem.unreachable
            : PairingV2Problem.failed,
      );
      _expireIfDue();
    }
  }

  /// Saves the claimed token as the v1 path does. The request is claimed
  /// now, so a failed save (the Keystore refused) ends it: the user starts
  /// again.
  Future<void> _save(
    int generation,
    PairingV2State before,
    Uri gateway,
    String token,
  ) async {
    state = before.copyWith(phase: PairingV2Phase.paired);
    try {
      await ref.read(connectionProvider.notifier).savePairing(gateway, token);
    } on Exception {
      if (!ref.mounted || generation != _generation) return;
      _close();
      state = before.copyWith(
        phase: PairingV2Phase.failed,
        problem: PairingV2Problem.failed,
      );
      return;
    }
    if (!ref.mounted) return;
    _close();
    // A later pairing starts from the address again.
    state = const PairingV2State(PairingV2Phase.address);
  }

  /// The request's end came. A claim on its way is not thrown away: the
  /// Gateway's answer (a token, or 410/404) decides, and the request
  /// expires here only after it, if it is still open.
  void _expire() {
    if (state.phase == PairingV2Phase.claiming ||
        state.phase == PairingV2Phase.paired) {
      return;
    }
    _end(PairingV2Phase.expired);
  }

  void _expireIfDue() {
    final ends = state.expiresAt;
    if (ends != null && !ref.read(clockProvider)().isBefore(ends)) {
      _end(PairingV2Phase.expired);
    }
  }

  /// Maps a refusal of a claim. `410` does not say whether the request was
  /// denied or expired: past its end it expired, and after wrong codes it
  /// ended because of them; otherwise a browser denied it.
  void _ended(ApiError error, {required bool afterCode}) {
    switch (error.status) {
      case 410:
        final expired = !ref
            .read(clockProvider)()
            .isBefore(state.expiresAt ?? DateTime(0));
        if (expired) {
          _end(PairingV2Phase.expired);
        } else if (afterCode) {
          _end(PairingV2Phase.wrongCode, attemptsLeft: 0);
        } else {
          _end(PairingV2Phase.denied);
        }
      case 404:
        _end(PairingV2Phase.expired);
      case 409:
        // The request stays approved; the user removes a phone and tries
        // the code again.
        state = state.copyWith(problem: PairingV2Problem.tooManyPhones);
        _expireIfDue();
      default:
        _close();
        state = state.copyWith(
          phase: PairingV2Phase.failed,
          problem: PairingV2Problem.failed,
        );
    }
  }

  void _end(PairingV2Phase phase, {int? attemptsLeft}) {
    if (state.phase == PairingV2Phase.paired) return;
    _close();
    state = state.copyWith(phase: phase, attemptsLeft: attemptsLeft);
  }

  /// Back to the address, for a new request.
  void restart() {
    _close();
    state = const PairingV2State(PairingV2Phase.address);
  }
}
