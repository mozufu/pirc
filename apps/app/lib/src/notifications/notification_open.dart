import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../activity/activity_data.dart';
import '../chat/chat_data.dart';
import '../connection/connection.dart';
import '../platform/notifications.dart';
import '../platform/push.dart';
import '../router.dart';
import '../work/session_controller.dart';
import '../work/work_side.dart';

/// The page a question tap opens: it reconnects and reads the question's
/// state before anything can be sent (C § 6.2).
const notificationCheckPath = '/notification';

/// What a notification tap opens. The tap names IDs and, for a question, the
/// choice the user tapped; it is never an answer the app has not checked.
@immutable
sealed class NotificationOpen {
  const NotificationOpen();

  /// Null for anything that is not a target of this app's notifications.
  static NotificationOpen? parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final map = decoded;
    String? text(String key) {
      final value = map[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return switch (text('type')) {
      'question' => switch ((
        text('sessionId'),
        text('interactionId'),
        text('epoch'),
      )) {
        (final s?, final i?, final e?) => QuestionOpen(
          sessionId: s,
          interactionId: i,
          epoch: e,
          choice: text('choice'),
          label: text('label'),
        ),
        _ => null,
      },
      'session' =>
        text('sessionId') == null
            ? null
            : LocationOpen(workLocation(text('sessionId')!)),
      // "View and run" opens the missed run; "Skip…" opens it asking to skip.
      'run' =>
        text('runId') == null
            ? null
            : LocationOpen(
                Uri(
                  path: '/calendar',
                  queryParameters: {
                    'open': 'run:${text('runId')}',
                    if (text('action') == 'skip') 'action': 'skip',
                  },
                ).toString(),
              ),
      'schedules' => const LocationOpen('/calendar'),
      'calendar' => LocationOpen(
        text('eventId') != null && text('occurrenceStart') != null
            ? Uri(
                path: '/calendar',
                queryParameters: {
                  'open': 'event:${text('eventId')}:${text('occurrenceStart')}',
                },
              ).toString()
            : '/calendar',
      ),
      // Pot pushes open their target (default E), never with an answer.
      'approval' =>
        text('approvalId') == null
            ? null
            : LocationOpen(
                Uri(
                  path: '/work',
                  queryParameters: {'approval': text('approvalId')},
                ).toString(),
              ),
      'budget' =>
        text('budgetRequestId') == null
            ? null
            : LocationOpen(
                Uri(
                  path: '/chat',
                  queryParameters: {'budget': text('budgetRequestId')},
                ).toString(),
              ),
      'thread' =>
        text('threadId') == null
            ? null
            : LocationOpen(chatLocation(text('threadId')!)),
      'activityNotification' =>
        text('activityNotificationId') == null
            ? null
            : LocationOpen(
                notificationLocation(text('activityNotificationId')!),
              ),
      'activity' => const LocationOpen('/activity'),
      'settings' => const LocationOpen('/settings/notifications'),
      _ => null,
    };
  }

  /// Where the router goes.
  String get location;
}

/// An agent question: checked first, then answered in the app only.
class QuestionOpen extends NotificationOpen {
  const QuestionOpen({
    required this.sessionId,
    required this.interactionId,
    required this.epoch,
    this.choice,
    this.label,
  });

  final String sessionId;
  final String interactionId;
  final String epoch;

  /// The choice tapped in the expanded notification: preselected, not sent.
  final String? choice;
  final String? label;

  @override
  String get location => Uri(
    path: notificationCheckPath,
    queryParameters: {
      'session': sessionId,
      'interaction': interactionId,
      'epoch': epoch,
      'choice': ?choice,
      'label': ?label,
    },
  ).toString();
}

/// Any other target: a page of the app.
class LocationOpen extends NotificationOpen {
  const LocationOpen(this.location);

  @override
  final String location;
}

/// Follows notification taps (Android): the one that opened the app and
/// those that arrive while it runs. Kept alive by the app.
final notificationTapsProvider = Provider<void>((ref) {
  final platform = ref.watch(notificationsPlatformProvider);
  if (platform == null) return;
  void go(String json) {
    final open = NotificationOpen.parse(json);
    if (open != null) ref.read(routerProvider).go(open.location);
  }

  final subscription = platform.opens.listen(go);
  ref.onDispose(subscription.cancel);
  unawaited(
    platform.initialOpen().then(
      (json) {
        if (json != null) go(json);
      },
      // The engine has no channel (tests, other platforms).
      onError: (Object _) {},
    ),
  );
});

/// Tells the Kotlin background client (push receipt, the overlay) where the
/// Gateway is and this app's client ID, each time the app is online with a
/// pairing. Unpairing clears them ([ConnectionController.unpair]).
final backgroundTargetProvider = Provider<void>((ref) {
  final push = ref.watch(pushPlatformProvider);
  if (push == null || ref.watch(isWebProvider)) return;
  ref.listen(
    connectionProvider.select(
      (s) => s.phase == ConnectionPhase.online ? s.connection?.gateway : null,
    ),
    (_, gateway) {
      if (gateway == null) return;
      unawaited(
        push
            .configure(gateway, ref.read(clientIdProvider))
            .catchError((Object _) {}),
      );
    },
    fireImmediately: true,
  );
});
