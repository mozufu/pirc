import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import 'chat_data.dart';

/// What a pot holds (responsibilities, pending reminders, works it
/// coordinates, groups it hosts). A handover or a retire changes it, and
/// so does an edit of the pot or a group: read again on `pots_changed` and
/// `threads_changed`.
final heldProvider = FutureProvider.autoDispose.family<List<HeldItem>, String>((
  ref,
  potId,
) {
  watchHint(ref, 'pots_changed');
  watchHint(ref, 'threads_changed');
  return PotsApi(requireApi(ref)).held(potId);
});

/// One item's identity in a pot's held list.
String heldKey(HeldItem item) => '${item.kind}:${item.ref}';

/// A retire plan, as the key of [retirePreviewProvider]: two plans are
/// equal when they ask the same of the same pot.
@immutable
class RetirePlan {
  const RetirePlan(this.potId, this.mode, this.targets);

  final String potId;

  /// `archive` or `delete`.
  final String mode;
  final List<RetireTarget> targets;

  List<String> get _keys => [
    for (final target in targets)
      '${heldKey(target.item)}>${target.to.kind}:${target.to.potId ?? ''}',
  ];

  @override
  bool operator ==(Object other) =>
      other is RetirePlan &&
      other.potId == potId &&
      other.mode == mode &&
      listEquals(other._keys, _keys);

  @override
  int get hashCode => Object.hash(potId, mode, Object.hashAll(_keys));
}

/// What retiring a pot with a plan would do: each item's fit at its
/// target, what stops and what is kept (nothing is changed). Read again on
/// `pots_changed` and `threads_changed`.
final retirePreviewProvider = FutureProvider.autoDispose
    .family<RetirePreview, RetirePlan>((ref, plan) {
      watchHint(ref, 'pots_changed');
      watchHint(ref, 'threads_changed');
      return PotsApi(
        requireApi(ref),
      ).retirePreview(plan.potId, mode: plan.mode, targets: plan.targets);
    });

/// The tag of a held item's kind (`e-tag`).
String heldKindLabel(AppLocalizations l10n, String kind) => switch (kind) {
  'responsibility' => l10n.handoverKindResponsibility,
  'reminder' => l10n.handoverKindReminder,
  'work' => l10n.handoverKindWork,
  'group_host' => l10n.handoverKindGroupHost,
  _ => kind,
};

HandoverFit handoverFit(String fit) => switch (fit) {
  'ok' => HandoverFit.ok,
  'narrowed' => HandoverFit.narrowed,
  _ => HandoverFit.stop,
};

/// The fit line: the Gateway's reason as it is; an ok item has none, so
/// the app says the permissions are enough (or, for the user, that the
/// user manages it).
String fitText(
  AppLocalizations l10n,
  String fit,
  String? reason,
  HandoverTo to,
) {
  if (reason != null && reason.isNotEmpty) return reason;
  if (fit == 'ok') {
    return to.kind == 'user' ? l10n.handoverFitOkYou : l10n.handoverFitOk;
  }
  return '';
}

/// The line under an item's title: a responsibility's detail, a group's
/// size; nothing for reminders and works (the API gives only their label).
String? heldSubtitle(
  AppLocalizations l10n,
  HeldItem item, {
  Pot? from,
  List<PotThread> threads = const [],
}) {
  switch (item.kind) {
    case 'responsibility':
      for (final duty in from?.work.responsibilities ?? const []) {
        if (duty.title == item.label && duty.detail.isNotEmpty) {
          return duty.detail;
        }
      }
      return null;
    case 'group_host':
      for (final thread in threads) {
        if (thread.id == item.ref) {
          return l10n.handoverGroupPots(thread.pots.length);
        }
      }
      return null;
  }
  return null;
}

/// What an item needs and what it does (E16), by kind. The Gateway checks
/// each kind against the receiver as these lines say (`handover.rs` fit).
List<String> heldDetails(AppLocalizations l10n, HeldItem item, Pot? from) {
  final name = from?.name ?? '';
  switch (item.kind) {
    case 'responsibility':
      final reach = switch (from?.permissions.reach) {
        'work' => l10n.potReachWork,
        'observe' => l10n.potReachObserve,
        _ => l10n.potReachAnswer,
      };
      String? detail;
      for (final duty in from?.work.responsibilities ?? const []) {
        if (duty.title == item.label && duty.detail.isNotEmpty) {
          detail = duty.detail;
        }
      }
      return [
        l10n.handoverNeedsReach(reach, name),
        if (detail != null) l10n.handoverWillDo(detail),
      ];
    case 'reminder':
      return [l10n.handoverNeedsNothing, l10n.handoverReminderDoes];
    case 'work':
      return [l10n.handoverNeedsWork, l10n.handoverWorkDoes(name)];
    case 'group_host':
      return [l10n.handoverNeedsMember, l10n.handoverHostDoes];
  }
  return const [];
}

/// The name of a receiver.
String receiverName(
  AppLocalizations l10n,
  HandoverTo to,
  List<PotSummary> pots,
) => switch (to.kind) {
  'user' => l10n.chatAuthorYou,
  'pot' => potNamed(pots, to.potId)?.name ?? '',
  _ => l10n.handoverNoOne,
};

PotSummary? potNamed(List<PotSummary> pots, String? id) {
  for (final pot in pots) {
    if (pot.id == id) return pot;
  }
  return null;
}

/// Where a pot's handover screens go back to: its profile.
String handoverBackLocation(String? potId) =>
    potId == null ? '/chat' : potProfileLocation(potId);
