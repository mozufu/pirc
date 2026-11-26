import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../format.dart';
import '../platform/notifications.dart';
import '../platform/push.dart';
import 'settings_widgets.dart';

/// `GET /api/push`: the push targets the Gateway knows.
final pushTargetsProvider = FutureProvider.autoDispose<Map<String, Object?>>(
  (ref) => PushApi(requireApi(ref)).status(),
);

/// The D20 categories in the order the page lists them.
const pushCategories = ['needs_you', 'done', 'progress', 'calendar'];

/// What a category is set to when the Gateway does not say (its defaults).
const _defaultLevels = {
  'needs_you': 'immediate',
  'done': 'digest',
  'progress': 'off',
  'calendar': 'immediate',
};

/// Settings → Notifications (C screenshots 11 and 30, D20): on Android this
/// phone's push (on or off, the UnifiedPush distributor, "Send test"), its
/// preferences at the Gateway (the four levels, the summary time, quiet
/// hours, the lock screen), the notification permission and the quick-reply
/// overlay switch. Every platform lists where notifications go.
///
/// Preferences are saved one change at a time with the target's revision; a
/// change made elsewhere meanwhile shows the current values and says so.
class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  PushStatus? _push;
  List<PushDistributor>? _distributors;
  String? _chosen;
  NotificationPermission? _permission;
  OverlaySetting? _overlay;
  bool _switching = false;

  /// This phone's target as the last save or conflict gave it.
  Map<String, Object?>? _saved;
  bool _conflict = false;
  bool _saving = false;
  final _subscriptions = <StreamSubscription<Object?>>[];

  PushPlatform? get _platform => ref.read(pushPlatformProvider);
  NotificationsPlatform? get _system => ref.read(notificationsPlatformProvider);

  @override
  void initState() {
    super.initState();
    final push = _platform;
    if (push != null) {
      _subscriptions.add(
        push.changes.listen((status) {
          if (!mounted) return;
          setState(() => _push = status);
          // A new target for this phone, or one Kotlin changed (its time zone).
          ref.invalidate(pushTargetsProvider);
        }),
      );
    }
    final system = _system;
    if (system != null) {
      _subscriptions.add(system.resumed.listen((_) => _loadSystem()));
    }
    unawaited(_loadPush());
    unawaited(_loadSystem());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Future<void> _loadPush() async {
    final push = _platform;
    if (push == null) return;
    try {
      final status = await push.status();
      final distributors = await push.distributors();
      if (!mounted) return;
      setState(() {
        _push = status;
        _distributors = distributors;
        _chosen = status.distributor ?? _chosen;
      });
    } on Exception {
      // No channel (another platform build): the page shows no push.
    }
  }

  Future<void> _loadSystem() async {
    final system = _system;
    if (system == null) return;
    try {
      final permission = await system.permission();
      final overlay = await system.overlay();
      if (!mounted) return;
      setState(() {
        _permission = permission;
        _overlay = overlay;
      });
    } on Exception {
      // As above.
    }
  }

  void _failed(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).actionFailed(message)),
      ),
    );
  }

  /// The distributor push would use: the chosen one, or the only one.
  String? get _distributor {
    final installed = _distributors ?? const [];
    if (_chosen != null && installed.any((d) => d.id == _chosen)) {
      return _chosen;
    }
    return installed.length == 1 ? installed.single.id : null;
  }

  Future<void> _setPush(bool on) async {
    final push = _platform;
    if (push == null) return;
    final distributor = _distributor;
    if (on && distributor == null) return;
    setState(() => _switching = true);
    try {
      if (on) {
        // The permission is asked from this page (or at the first question).
        final system = _system;
        final permission = _permission;
        if (system != null &&
            permission != null &&
            !permission.granted &&
            permission.canAsk) {
          final answer = await system.requestPermission();
          if (mounted) setState(() => _permission = answer);
        }
        final status = await push.enable(distributor!);
        if (mounted) setState(() => _push = status);
      } else {
        final status = await push.disable();
        if (mounted) setState(() => _push = status);
      }
      ref.invalidate(pushTargetsProvider);
    } on Exception catch (error) {
      _failed(_message(error));
      unawaited(_loadPush());
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _chooseDistributor(String id) async {
    setState(() => _chosen = id);
    // A running registration moves to the new distributor.
    if (_push?.state != PushState.off) await _setPush(true);
  }

  Future<void> _askPermission() async {
    final system = _system;
    if (system == null) return;
    final answer = await system.requestPermission();
    if (mounted) setState(() => _permission = answer);
  }

  Future<void> _setOverlay(bool on) async {
    final system = _system;
    if (system == null) return;
    final overlay = await system.setOverlay(on);
    if (mounted) setState(() => _overlay = overlay);
  }

  Future<void> _sendTest() async {
    final l10n = AppLocalizations.of(context);
    try {
      final count = await PushApi(ref.read(apiProvider)!).sendTest();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.pushSent(count))));
      }
    } on PircException catch (error) {
      _failed(error.message);
    }
  }

  /// Saves one change of [target] at its revision.
  Future<void> _save(
    Map<String, Object?> target, {
    Map<String, String>? levels,
    bool setQuietHours = false,
    ({String start, String end})? quietHours,
    String? lockScreen,
    String? digestAt,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await PushApi(ref.read(apiProvider)!).update(
        '${target['id']}',
        revision: (target['revision'] as num?)?.toInt() ?? 0,
        levels: levels,
        setQuietHours: setQuietHours,
        quietHours: quietHours,
        lockScreen: lockScreen,
        digestAt: digestAt,
      );
      if (mounted) {
        setState(() {
          _saved = saved;
          _conflict = false;
        });
      }
    } on ApiError catch (error) {
      final details = error.details;
      final current = details is Map ? details['subscription'] : null;
      if (error.status == 409 && current is Map) {
        if (mounted) {
          setState(() {
            _saved = current.cast<String, Object?>();
            _conflict = true;
          });
        }
      } else {
        _failed(error.message);
      }
    } on PircException catch (error) {
      _failed(error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _message(Object error) => switch (error) {
    PircException(:final message) => message,
    _ => '$error',
  };

  /// This phone's target: the newer of the listed one and the last saved.
  Map<String, Object?>? _target(List<Map<String, Object?>> targets) {
    final id = _push?.subscriptionId;
    if (id == null) return null;
    final listed = targets.where((t) => t['id'] == id).firstOrNull;
    final saved = _saved;
    if (saved == null || saved['id'] != id) return listed;
    if (listed == null) return saved;
    final a = (listed['revision'] as num?)?.toInt() ?? 0;
    final b = (saved['revision'] as num?)?.toInt() ?? 0;
    return b >= a ? saved : listed;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(pushTargetsProvider);
    final android = ref.watch(pushPlatformProvider) != null;
    final List<Widget> children = switch (value) {
      AsyncValue(:final value?) => _page(context, value, android),
      AsyncValue(:final error?) when error is! NotConnected => [
        ListTile(
          leading: const Icon(LucideIcons.circleAlert),
          title: Text(l10n.listFailed),
          trailing: TextButton(
            onPressed: () => ref.invalidate(pushTargetsProvider),
            child: Text(l10n.retry),
          ),
        ),
      ],
      _ => [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
    };
    return SettingsPage(title: l10n.settingsNotifications, children: children);
  }

  List<Widget> _page(
    BuildContext context,
    Map<String, Object?> data,
    bool android,
  ) {
    final l10n = AppLocalizations.of(context);
    final targets = [
      for (final t in (data['subscriptions'] as List? ?? const []))
        if (t is Map) t.cast<String, Object?>(),
    ];
    final target = _target(targets);
    return [
      if (android) ...[
        _StatusCard(
          push: _push,
          target: target,
          distributorName: _distributors
              ?.where((d) => d.id == _push?.distributor)
              .firstOrNull
              ?.name,
          onSendTest: targets.isEmpty ? null : _sendTest,
        ),
        _pushGroup(context),
        if (_conflict)
          _Note(text: l10n.pushConflict, icon: LucideIcons.circleAlert),
        if (_push?.state == PushState.on && target == null)
          _Note(text: l10n.pushTargetGone, icon: LucideIcons.circleAlert),
        if (target != null) ..._preferences(context, target),
        _permissionGroup(context),
        _styleGroup(context),
      ],
      SettingsGroup(
        title: l10n.pushTargets,
        children: [
          if (targets.isEmpty) ListTile(title: Text(l10n.pushNone)),
          for (final t in targets)
            ListTile(
              leading: Icon(
                t['failing'] == true ? LucideIcons.bellOff : LucideIcons.bell,
                size: 20,
              ),
              title: Text('${t['name']}'),
              subtitle: Text(
                t['failing'] == true
                    ? l10n.pushFailing
                    : t['id'] == _push?.subscriptionId
                    ? l10n.pushThisDevice
                    : '${t['kind']}',
              ),
              trailing: TextButton(
                onPressed: () async {
                  try {
                    await PushApi(ref.read(apiProvider)!).remove('${t['id']}');
                    ref.invalidate(pushTargetsProvider);
                  } on PircException catch (error) {
                    _failed(error.message);
                  }
                },
                child: Text(l10n.deviceRevoke),
              ),
            ),
        ],
      ),
      if (!android && targets.isNotEmpty)
        SettingsGroup(
          children: [
            ListTile(
              leading: const Icon(LucideIcons.send, size: 20),
              title: Text(l10n.pushSendTest),
              onTap: _sendTest,
            ),
          ],
        ),
    ];
  }

  Widget _pushGroup(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final installed = _distributors;
    final on = _push != null && _push!.state != PushState.off;
    final none = installed != null && installed.isEmpty;
    return SettingsGroup(
      children: [
        SwitchListTile(
          key: const Key('push-switch'),
          title: Text(l10n.pushOn),
          value: on && !none,
          onChanged: _switching || none || installed == null
              ? null
              : (value) =>
                    value && _distributor == null ? null : _setPush(value),
        ),
        if (none)
          ListTile(
            leading: const Icon(LucideIcons.download, size: 20),
            title: Text(l10n.pushNoDistributor),
          )
        else if (installed != null && installed.length == 1)
          ListTile(
            title: Text(l10n.pushDistributor),
            trailing: Text(installed.single.name),
          )
        else if (installed != null)
          ListTile(
            title: Text(l10n.pushDistributor),
            trailing: DropdownButton<String>(
              key: const Key('push-distributor'),
              value: _distributor,
              hint: Text(l10n.pushChooseDistributor),
              underline: const SizedBox.shrink(),
              onChanged: _switching
                  ? null
                  : (id) => id == null ? null : _chooseDistributor(id),
              items: [
                for (final d in installed)
                  DropdownMenuItem(value: d.id, child: Text(d.name)),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _preferences(BuildContext context, Map<String, Object?> target) {
    final l10n = AppLocalizations.of(context);
    final levels = {
      ..._defaultLevels,
      if (target['levels'] case final Map map)
        for (final MapEntry(:key, :value) in map.entries) '$key': '$value',
    };
    final quiet = target['quietHours'];
    final quietStart = quiet is Map ? '${quiet['start']}' : null;
    final quietEnd = quiet is Map ? '${quiet['end']}' : null;
    final digestAt = '${target['digestAt'] ?? '18:00'}';
    final lock = '${target['lockScreen'] ?? 'title'}';
    final enabled = !_saving;
    Widget time(String key, String value, ValueChanged<String> onPicked) =>
        TextButton(
          key: Key(key),
          onPressed: enabled
              ? () async {
                  final picked = await _pickTime(context, value);
                  if (picked != null && picked != value) onPicked(picked);
                }
              : null,
          child: Text(value),
        );
    return [
      SettingsGroup(
        title: l10n.pushCategories,
        children: [
          for (final category in pushCategories)
            ListTile(
              title: Text(_categoryName(l10n, category)),
              subtitle: Text(_categoryNote(l10n, category)),
              trailing: DropdownButton<String>(
                key: Key('level-$category'),
                value: levels[category],
                underline: const SizedBox.shrink(),
                onChanged: enabled
                    ? (level) => level == null || level == levels[category]
                          ? null
                          : _save(target, levels: {category: level})
                    : null,
                items: [
                  for (final (level, label) in [
                    ('immediate', l10n.pushLevelImmediate),
                    ('digest', l10n.pushLevelDigest),
                    ('off', l10n.pushLevelOff),
                  ])
                    DropdownMenuItem(value: level, child: Text(label)),
                ],
              ),
            ),
          ListTile(
            title: Text(l10n.pushDigestAt),
            subtitle: Text(l10n.pushDigestAtNote),
            trailing: time(
              'digest-at',
              digestAt,
              (picked) => _save(target, digestAt: picked),
            ),
          ),
        ],
      ),
      SettingsGroup(
        title: l10n.pushQuietHours,
        children: [
          SwitchListTile(
            key: const Key('quiet-hours'),
            title: Text(l10n.pushQuietHours),
            subtitle: Text(l10n.pushQuietHoursNote),
            value: quiet is Map,
            onChanged: enabled
                ? (on) => _save(
                    target,
                    setQuietHours: true,
                    quietHours: on ? (start: '22:00', end: '07:00') : null,
                  )
                : null,
          ),
          if (quietStart != null && quietEnd != null) ...[
            ListTile(
              title: Text(l10n.pushQuietStart),
              trailing: time(
                'quiet-start',
                quietStart,
                (picked) => picked == quietEnd
                    ? null
                    : _save(
                        target,
                        setQuietHours: true,
                        quietHours: (start: picked, end: quietEnd),
                      ),
              ),
            ),
            ListTile(
              title: Text(l10n.pushQuietEnd),
              trailing: time(
                'quiet-end',
                quietEnd,
                (picked) => picked == quietStart
                    ? null
                    : _save(
                        target,
                        setQuietHours: true,
                        quietHours: (start: quietStart, end: picked),
                      ),
              ),
            ),
          ],
        ],
      ),
      SettingsGroup(
        title: l10n.pushLockScreen,
        children: [
          ListTile(
            title: Text(l10n.pushLockScreenShows),
            trailing: DropdownButton<String>(
              key: const Key('lock-screen'),
              value: lock,
              underline: const SizedBox.shrink(),
              onChanged: enabled
                  ? (value) => value == null || value == lock
                        ? null
                        : _save(target, lockScreen: value)
                  : null,
              items: [
                for (final (value, label) in [
                  ('hidden', l10n.pushLockHidden),
                  ('title', l10n.pushLockTitle),
                  ('full', l10n.pushLockFull),
                ])
                  DropdownMenuItem(value: value, child: Text(label)),
              ],
            ),
          ),
        ],
      ),
      // Android uses the public version only while its own lock screen
      // setting hides sensitive content.
      _Note(text: l10n.pushLockScreenNote),
      if ('${target['timeZone'] ?? ''}'.isNotEmpty)
        _Note(text: l10n.pushTimeZone('${target['timeZone']}')),
    ];
  }

  Widget _permissionGroup(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permission = _permission;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (permission != null)
          SettingsGroup(
            title: l10n.pushPermissionTitle,
            children: [
              ListTile(
                leading: Icon(
                  permission.granted
                      ? LucideIcons.bellRing
                      : LucideIcons.bellOff,
                  size: 20,
                ),
                title: Text(
                  permission.granted
                      ? l10n.pushPermissionGranted
                      : l10n.pushPermissionDenied,
                ),
                trailing: permission.granted
                    ? null
                    : permission.canAsk
                    ? TextButton(
                        key: const Key('ask-permission'),
                        onPressed: _askPermission,
                        child: Text(l10n.pushPermissionAsk),
                      )
                    : null,
              ),
            ],
          ),
        _Note(text: l10n.pushChannelsNote),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PircSpacing.gutterGroupedText,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => _system?.openSettings(),
              child: Text(l10n.pushOpenSystemSettings),
            ),
          ),
        ),
      ],
    );
  }

  Widget _styleGroup(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final overlay = _overlay;
    return SettingsGroup(
      title: l10n.pushStyle,
      children: [
        SwitchListTile(
          key: const Key('overlay-switch'),
          title: Text(l10n.quickReplyOverlay),
          subtitle: Text(
            overlay != null && overlay.wanted && !overlay.allowed
                ? '${l10n.quickReplyOverlayNote}\n${l10n.quickReplyOverlayWaiting}'
                : l10n.quickReplyOverlayNote,
          ),
          // Off until "Display over other apps" is granted.
          value: overlay?.on ?? false,
          onChanged: overlay == null ? null : _setOverlay,
        ),
      ],
    );
  }

  static String _categoryName(AppLocalizations l10n, String category) =>
      switch (category) {
        'needs_you' => l10n.pushCategoryNeedsYou,
        'done' => l10n.pushCategoryDone,
        'progress' => l10n.pushCategoryProgress,
        _ => l10n.pushCategoryCalendar,
      };

  static String _categoryNote(AppLocalizations l10n, String category) =>
      switch (category) {
        'needs_you' => l10n.pushCategoryNeedsYouNote,
        'done' => l10n.pushCategoryDoneNote,
        'progress' => l10n.pushCategoryProgressNote,
        _ => l10n.pushCategoryCalendarNote,
      };
}

/// A 24-hour `HH:MM` from the time picker, starting at [value].
Future<String?> _pickTime(BuildContext context, String value) async {
  final parts = value.split(':');
  final initial = TimeOfDay(
    hour: int.tryParse(parts.first) ?? 0,
    minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
  );
  final picked = await showTimePicker(
    context: context,
    initialTime: initial,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
  if (picked == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(picked.hour)}:${two(picked.minute)}';
}

/// "This phone gets notifications", how, and "Send test".
class _StatusCard extends ConsumerWidget {
  const _StatusCard({
    required this.push,
    required this.target,
    required this.distributorName,
    required this.onSendTest,
  });

  final PushStatus? push;
  final Map<String, Object?>? target;
  final String? distributorName;
  final VoidCallback? onSendTest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final state = push?.state ?? PushState.off;
    final last = (target?['lastSuccessAt'] as num?)?.toInt();
    final (Color dot, String title) = switch (state) {
      PushState.on => (colors['status.success'], l10n.pushThisPhoneOn),
      PushState.connecting => (colors['status.warning'], l10n.pushConnecting),
      PushState.failed => (colors['status.danger'], l10n.pushSetupFailed),
      PushState.off => (colors['text.faint'], l10n.pushThisPhoneOff),
    };
    final detail = [
      if (state == PushState.failed && (push?.error ?? '').isNotEmpty)
        push!.error!
      else ...[
        'UnifiedPush',
        ?distributorName,
        if (last != null && last > 0)
          l10n.pushLastDelivered(
            clockTime(context, last, now: ref.read(clockProvider)()),
          ),
      ],
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PircSpacing.gutterPhone,
        PircSpacing.stackLg,
        PircSpacing.gutterPhone,
        0,
      ),
      child: Material(
        color: colors['surface.layer'],
        borderRadius: BorderRadius.circular(PircRadius.lg),
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.stackLg),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: PircSpacing.stackMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleMedium),
                    Text(detail, style: text.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: PircSpacing.stackSm),
              FilledButton.tonal(
                key: const Key('send-test'),
                onPressed: onSendTest,
                child: Text(l10n.pushSendTest),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A line of explanation between groups.
class _Note extends StatelessWidget {
  const _Note({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PircSpacing.gutterGroupedText,
        PircSpacing.stackMd,
        PircSpacing.gutterGroupedText,
        PircSpacing.stackSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: style?.color),
            const SizedBox(width: PircSpacing.stackSm),
          ],
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
