import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Links into and out of the app, through the `org.mozufu.pirc/links`
/// channel (plans/roadmap.md M8 step 2): the `pirc://pair` links that open
/// the app, and the browser for the pairing v2 approval page. A pairing link
/// holds a token, so it is never logged.
abstract interface class AppLinks {
  /// The pairing link that opened the app, or one that arrived before Dart
  /// listened; given once.
  Future<String?> initialLink();

  /// Pairing links that arrive while the app runs.
  Stream<String> get links;

  /// Opens an http(s) [address] in the browser. Throws [PlatformException]
  /// (`NO_BROWSER`) when no app can open it.
  Future<void> openBrowser(Uri address);
}

class ChannelAppLinks implements AppLinks {
  ChannelAppLinks();

  static const channel = MethodChannel('org.mozufu.pirc/links');

  StreamController<String>? _links;

  @override
  Future<String?> initialLink() => channel.invokeMethod<String>('initialLink');

  @override
  Stream<String> get links {
    final links = _links ??= StreamController<String>.broadcast(
      onListen: () => channel.setMethodCallHandler((call) async {
        if (call.method == 'link' && call.arguments is String) {
          _links?.add(call.arguments as String);
        }
      }),
      onCancel: () => channel.setMethodCallHandler(null),
    );
    return links.stream;
  }

  @override
  Future<void> openBrowser(Uri address) =>
      channel.invokeMethod<void>('openBrowser', {'url': address.toString()});
}

/// For tests: [initial] once, links pushed with [push], opened addresses in
/// [opened].
class FakeAppLinks implements AppLinks {
  FakeAppLinks({this.initial, this.browserFails = false});

  String? initial;
  bool browserFails;
  final opened = <Uri>[];
  final _links = StreamController<String>.broadcast();

  void push(String link) => _links.add(link);

  @override
  Future<String?> initialLink() async {
    final link = initial;
    initial = null;
    return link;
  }

  @override
  Stream<String> get links => _links.stream;

  @override
  Future<void> openBrowser(Uri address) async {
    if (browserFails) throw PlatformException(code: 'NO_BROWSER');
    opened.add(address);
  }
}

/// The links of this platform: Android only. Elsewhere the approval address
/// is shown to open by hand.
final appLinksProvider = Provider<AppLinks?>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? ChannelAppLinks()
      : null,
);
