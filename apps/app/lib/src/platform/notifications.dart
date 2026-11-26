import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app may show notifications (Android 13+ asks for it).
@immutable
class NotificationPermission {
  const NotificationPermission({required this.granted, required this.canAsk});

  static NotificationPermission fromMap(Object? value) {
    final map = value is Map ? value : const {};
    return NotificationPermission(
      granted: map['granted'] == true,
      canAsk: map['canAsk'] == true,
    );
  }

  final bool granted;

  /// Asking can help; when false and not [granted], only the system
  /// settings can turn notifications on.
  final bool canAsk;
}

/// The quick-reply overlay switch (step 4). [on] only when the user [wanted]
/// it and "Display over other apps" is [allowed].
@immutable
class OverlaySetting {
  const OverlaySetting({
    required this.on,
    required this.wanted,
    required this.allowed,
  });

  static OverlaySetting fromMap(Object? value) {
    final map = value is Map ? value : const {};
    return OverlaySetting(
      on: map['on'] == true,
      wanted: map['wanted'] == true,
      allowed: map['allowed'] == true,
    );
  }

  final bool on;
  final bool wanted;
  final bool allowed;
}

/// Notification taps into the app and the permissions of Settings →
/// Notifications, through the `org.mozufu.pirc/notifications` channel
/// (plans/roadmap.md M8 step 3). A tap is a JSON target that names IDs and
/// the tapped choice, never an answer: the app checks the state first.
abstract interface class NotificationsPlatform {
  /// The tap that opened the app, or one that arrived before Dart listened;
  /// given once.
  Future<String?> initialOpen();

  /// Taps while the app runs.
  Stream<String> get opens;

  /// The app came back to the foreground (a permission may have changed in
  /// the system settings meanwhile).
  Stream<void> get resumed;

  Future<NotificationPermission> permission();

  /// Asks for the permission (Android 13+); only Settings → Notifications
  /// calls this.
  Future<NotificationPermission> requestPermission();

  /// Opens the system notification settings of the app.
  Future<void> openSettings();

  Future<OverlaySetting> overlay();

  /// Stores the switch; turning it on without the permission opens the
  /// system page for "Display over other apps".
  Future<OverlaySetting> setOverlay(bool on);
}

class ChannelNotifications implements NotificationsPlatform {
  ChannelNotifications();

  static const channel = MethodChannel('org.mozufu.pirc/notifications');

  StreamController<(String, Object?)>? _events;

  Stream<(String, Object?)> get _calls {
    final events = _events ??= StreamController<(String, Object?)>.broadcast(
      onListen: () => channel.setMethodCallHandler((call) async {
        _events?.add((call.method, call.arguments));
      }),
      onCancel: () => channel.setMethodCallHandler(null),
    );
    return events.stream;
  }

  @override
  Future<String?> initialOpen() => channel.invokeMethod<String>('initialOpen');

  @override
  Stream<String> get opens => _calls
      .where((call) => call.$1 == 'open' && call.$2 is String)
      .map((call) => call.$2! as String);

  @override
  Stream<void> get resumed => _calls.where((call) => call.$1 == 'resumed');

  @override
  Future<NotificationPermission> permission() async =>
      NotificationPermission.fromMap(
        await channel.invokeMethod<Object?>('permission'),
      );

  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.fromMap(
        await channel.invokeMethod<Object?>('requestPermission'),
      );

  @override
  Future<void> openSettings() => channel.invokeMethod<void>('openSettings');

  @override
  Future<OverlaySetting> overlay() async =>
      OverlaySetting.fromMap(await channel.invokeMethod<Object?>('overlay'));

  @override
  Future<OverlaySetting> setOverlay(bool on) async => OverlaySetting.fromMap(
    await channel.invokeMethod<Object?>('setOverlay', {'on': on}),
  );
}

/// For tests: taps pushed with [tap], permissions and the overlay switch in
/// memory.
class FakeNotifications implements NotificationsPlatform {
  FakeNotifications({
    this.initial,
    this.granted = false,
    this.canAsk = true,
    this.grantOnAsk = true,
    this.overlayAllowed = false,
  });

  String? initial;
  bool granted;
  bool canAsk;
  bool grantOnAsk;
  bool overlayAllowed;
  bool overlayWanted = false;
  int asked = 0;
  int overlayPages = 0;
  int settingsOpened = 0;
  final _opens = StreamController<String>.broadcast();
  final _resumed = StreamController<void>.broadcast();

  void tap(String target) => _opens.add(target);

  void resume() => _resumed.add(null);

  @override
  Future<String?> initialOpen() async {
    final target = initial;
    initial = null;
    return target;
  }

  @override
  Stream<String> get opens => _opens.stream;

  @override
  Stream<void> get resumed => _resumed.stream;

  @override
  Future<NotificationPermission> permission() async =>
      NotificationPermission(granted: granted, canAsk: canAsk && !granted);

  @override
  Future<NotificationPermission> requestPermission() async {
    asked++;
    if (grantOnAsk) granted = true;
    return permission();
  }

  @override
  Future<void> openSettings() async => settingsOpened++;

  OverlaySetting get _overlay => OverlaySetting(
    on: overlayWanted && overlayAllowed,
    wanted: overlayWanted,
    allowed: overlayAllowed,
  );

  @override
  Future<OverlaySetting> overlay() async => _overlay;

  @override
  Future<OverlaySetting> setOverlay(bool on) async {
    overlayWanted = on;
    if (on && !overlayAllowed) overlayPages++;
    return _overlay;
  }
}

/// Notifications of this platform: Android only.
final notificationsPlatformProvider = Provider<NotificationsPlatform?>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? ChannelNotifications()
      : null,
);
