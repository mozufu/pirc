import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import 'connection.dart';

/// A parsed `pirc://pair?url=<origin>&token=<token>` link (pairing v1).
@immutable
class PairingLink {
  const PairingLink(this.gateway, this.token);

  final Uri gateway;
  final String token;

  /// Null when [text] is not a pairing link with an http(s) origin and a
  /// token.
  static PairingLink? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'pirc' || uri.host != 'pair') {
      return null;
    }
    final url = Uri.tryParse(uri.queryParameters['url'] ?? '');
    final token = uri.queryParameters['token'] ?? '';
    if (url == null ||
        !(url.scheme == 'https' || url.scheme == 'http') ||
        url.host.isEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        url.userInfo.isNotEmpty ||
        !(url.path.isEmpty || url.path == '/') ||
        token.isEmpty) {
      return null;
    }
    return PairingLink(url.replace(path: '/'), token);
  }
}

enum PairingPhase { idle, checking, invalid, paired }

/// Why a link was not accepted.
enum PairingProblem { notALink, tokenRefused, appTooOld, unreachable, failed }

@immutable
class PairingState {
  const PairingState(this.phase, {this.problem});
  final PairingPhase phase;
  final PairingProblem? problem;
}

final pairingProvider = NotifierProvider<PairingController, PairingState>(
  PairingController.new,
);

/// Checks a pasted link with `ApiClient.connect()` before saving the token.
class PairingController extends Notifier<PairingState> {
  @override
  PairingState build() => const PairingState(PairingPhase.idle);

  Future<void> submit(String text) async {
    if (state.phase == PairingPhase.checking) return;
    final link = PairingLink.parse(text);
    if (link == null) {
      state = const PairingState(
        PairingPhase.invalid,
        problem: PairingProblem.notALink,
      );
      return;
    }
    state = const PairingState(PairingPhase.checking);
    final transport = ref.read(transportFactoryProvider)(
      TransportConfig(baseUri: link.gateway),
      StaticTokenStore(link.token),
    );
    try {
      await ApiClient(transport).connect();
    } on PircException catch (error) {
      state = PairingState(
        PairingPhase.invalid,
        problem: switch (error) {
          PairingRequired() => PairingProblem.tokenRefused,
          ClientUpgradeRequired() => PairingProblem.appTooOld,
          TransportException() => PairingProblem.unreachable,
          _ => PairingProblem.failed,
        },
      );
      return;
    } finally {
      transport.close();
    }
    state = const PairingState(PairingPhase.paired);
    await ref
        .read(connectionProvider.notifier)
        .savePairing(link.gateway, link.token);
  }

  void reset() => state = const PairingState(PairingPhase.idle);
}
