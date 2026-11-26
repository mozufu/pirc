import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import '../work/work_data.dart';
import 'pot_conversation_screen.dart';
import 'thread_data.dart';

/// The fewest and most member pots of a group (the Gateway's rule).
const groupMinMembers = 2;
const groupMaxMembers = 16;

/// A group's name is 1 to 60 characters.
const groupNameMax = 60;

/// A group read by its thread ID, for its info (E35); read again on
/// `threads_changed` and `pots_changed`. A deleted group answers 404.
final groupThreadProvider = FutureProvider.autoDispose
    .family<PotThread, String>((ref, id) {
      watchHint(ref, 'threads_changed');
      watchHint(ref, 'pots_changed');
      return ThreadsApi(requireApi(ref)).read(id);
    });

/// What keeps a group's input from being sent.
enum GroupIssue { nameMissing, nameTooLong, memberCount, hostMissing }

/// The problems of a group's [name], [members] and [host], as the Gateway
/// checks them: a name of 1–60 characters, 2–16 members and a host among
/// them.
Set<GroupIssue> groupIssues({
  required String name,
  required List<String> members,
  required String? host,
}) => {
  if (name.trim().isEmpty) GroupIssue.nameMissing,
  if (name.trim().characters.length > groupNameMax) GroupIssue.nameTooLong,
  if (members.length < groupMinMembers || members.length > groupMaxMembers)
    GroupIssue.memberCount,
  if (host == null || !members.contains(host)) GroupIssue.hostMissing,
};

String groupIssueText(AppLocalizations l10n, GroupIssue issue) =>
    switch (issue) {
      GroupIssue.nameMissing => l10n.groupNameMissing,
      GroupIssue.nameTooLong => l10n.potTooLong(groupNameMax),
      GroupIssue.memberCount => l10n.groupMemberRule,
      GroupIssue.hostMissing => l10n.groupHostMissing,
    };

/// [ids] in the order of [pots] (the Gateway's), so a request does not
/// depend on the order the user ticked them in.
List<String> inPotOrder(Iterable<String> ids, List<PotSummary> pots) {
  final set = ids.toSet();
  return [
    for (final pot in pots)
      if (set.contains(pot.id)) pot.id,
    // Members the list does not know (yet) keep their place at the end.
    for (final id in ids)
      if (!pots.any((p) => p.id == id)) id,
  ];
}

/// The group's member pots that still exist, host first, then in the
/// thread's order.
List<PotSummary> groupMembers(PotThread thread, List<PotSummary> pots) {
  final byId = {for (final pot in pots) pot.id: pot};
  final members = [for (final id in thread.pots) ?byId[id]];
  final host = members.where((p) => p.id == thread.hostPotId);
  return [...host, ...members.where((p) => p.id != thread.hostPotId)];
}

/// "Manager · Can open work": a pot's intro and its state, or what it may
/// do once [full] is read.
String potMemberLine(AppLocalizations l10n, PotSummary pot, Pot? full) => [
  if (pot.intro.isNotEmpty) pot.intro,
  ?potStateLine(l10n, pot, full),
].join(' · ');

/// "Can open work · This month $4.20 / $20": what a member may do and its
/// budget used (the mention popover, the group's info).
String potReachBudgetLine(AppLocalizations l10n, PotSummary pot, Pot? full) => [
  if (pot.state == 'paused') l10n.potPaused else ?potReachLine(l10n, full),
  if (full != null) ?potBudgetLine(l10n, full),
].join(' · ');

/// Who a message in a group is for, as the composer collects it: some
/// members, or everyone.
@immutable
class GroupTargets {
  const GroupTargets({this.mentions = const [], this.all = false});

  /// Pot IDs, in the order they were picked.
  final List<String> mentions;

  /// Every member wakes.
  final bool all;

  bool get isEmpty => mentions.isEmpty && !all;

  /// Adds [potId], or switches to everyone with null ("@all" and single
  /// members exclude each other).
  GroupTargets pick(String? potId) {
    if (potId == null) return const GroupTargets(all: true);
    if (mentions.contains(potId)) return GroupTargets(mentions: mentions);
    return GroupTargets(mentions: [...mentions, potId]);
  }

  /// Takes [potId] out, or everyone with null.
  GroupTargets remove(String? potId) => potId == null
      ? GroupTargets(mentions: mentions)
      : GroupTargets(
          mentions: [
            for (final id in mentions)
              if (id != potId) id,
          ],
          all: all,
        );

  /// Drops members that left the group.
  GroupTargets within(List<String> members) => GroupTargets(
    mentions: [
      for (final id in mentions)
        if (members.contains(id)) id,
    ],
    all: all,
  );
}

/// Reads the pots in full for [ids] (their reach and budget); a pot that
/// fails is left out.
Map<String, Pot> watchFullPots(WidgetRef ref, Iterable<String> ids) => {
  for (final id in ids) id: ?ref.watch(potProvider(id)).value,
};

/// Reads the pots list once (for a request's order).
List<PotSummary> readPots(WidgetRef ref) =>
    ref.read(potsProvider).value ?? const <PotSummary>[];
