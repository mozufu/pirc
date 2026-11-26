import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../platform/links.dart';
import 'connection.dart';

/// Whether the app offers pairing v2 (plans/roadmap.md M8 default A): off
/// until the Web build serves the approval page (M9). Tests override it.
final pairingV2EnabledProvider = Provider<bool>(
  (ref) => const bool.fromEnvironment('PIRC_PAIRING_V2'),
);

/// A Gateway origin: http(s), a host, no user, path, query or fragment.
/// Null for anything else.
Uri? gatewayOrigin(String text) {
  final url = Uri.tryParse(text.trim());
  if (url == null ||
      !(url.scheme == 'https' || url.scheme == 'http') ||
      url.host.isEmpty ||
      url.hasQuery ||
      url.hasFragment ||
      url.userInfo.isNotEmpty ||
      !(url.path.isEmpty || url.path == '/')) {
    return null;
  }
  return url.replace(path: '/');
}

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
    final url = gatewayOrigin(uri.queryParameters['url'] ?? '');
    final token = uri.queryParameters['token'] ?? '';
    if (url == null || token.isEmpty) return null;
    return PairingLink(url, token);
  }
}

/// A `pirc://pair` link that opened the app (the links channel), waiting for
/// the pairing page to fill it in. The user still taps Pair: a link from any
/// web page must not pair the phone with another Gateway by itself. A
/// paired app drops it (any phase but starting and unpaired), so it never
/// pairs again from a link.
final pairLinkInboxProvider = NotifierProvider<PairLinkInbox, String?>(
  PairLinkInbox.new,
);

class PairLinkInbox extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(connectionProvider.select((s) => s.phase), (_, phase) {
      if (!_open(phase)) state = null;
    });
    final links = ref.watch(appLinksProvider);
    if (links != null) {
      final subscription = links.links.listen(_arrived);
      ref.onDispose(subscription.cancel);
      unawaited(
        links.initialLink().then(
          (link) {
            if (link != null) _arrived(link);
          },
          // The engine has no channel (tests, other platforms).
          onError: (Object _) {},
        ),
      );
    }
    return null;
  }

  static bool _open(ConnectionPhase phase) =>
      phase == ConnectionPhase.starting || phase == ConnectionPhase.unpaired;

  void _arrived(String link) {
    if (_open(ref.read(connectionProvider).phase)) state = link;
  }

  /// The pairing page took it.
  void take() => state = null;
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
