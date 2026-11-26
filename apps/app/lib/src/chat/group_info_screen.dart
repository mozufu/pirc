import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../work/work_data.dart';
import 'chat_data.dart';
import 'chat_list_screen.dart';
import 'group_data.dart';
import 'handover_parts.dart';
import 'new_group_screen.dart';
import 'new_pot_screen.dart';
import 'pot_form.dart';

/// A group's info (E35): its avatar and name with "Change name and
/// avatar", the members (you, then the host and the other pots, each
/// opening its profile) with "Add or remove members", the host, and
/// Delete group. Every edit is a `PATCH` with the revision the group had
/// when the edit started; a 409 reads the group again, keeps the edit and
/// says so. It sits in the Chat tab's side pane (`side=group-info`).
class GroupInfoScreen extends ConsumerWidget {
  const GroupInfoScreen({
    super.key,
    required this.threadId,
    required this.onClose,
    this.closeIcon = false,
  });

  final String threadId;
  final VoidCallback onClose;

  /// An ✕ instead of Back (the right column at 1200 and wider).
  final bool closeIcon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final value = ref.watch(groupThreadProvider(threadId));
    final thread = value.value;
    final Widget body;
    if (thread == null) {
      final error = value.error;
      body = error is ApiError && error.status == 404
          ? Center(child: GroupNote(l10n.groupGone))
          : value.hasError
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Text(l10n.listFailed),
                  OutlinedButton(
                    onPressed: () =>
                        ref.invalidate(groupThreadProvider(threadId)),
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator());
    } else {
      body = SingleChildScrollView(
        key: const ValueKey('group-info-scroll'),
        padding: const EdgeInsets.only(bottom: 24),
        child: _InfoBody(thread: thread),
      );
    }
    return Scaffold(
      key: const ValueKey('group-info'),
      backgroundColor: colors['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              title: l10n.groupInfo,
              leading: IconButton(
                tooltip: closeIcon ? l10n.close : l10n.back,
                color: colors['text.secondary'],
                onPressed: onClose,
                icon: Icon(
                  closeIcon ? LucideIcons.x : LucideIcons.chevronLeft,
                  size: PircSize.iconBar,
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _InfoBody extends ConsumerWidget {
  const _InfoBody({required this.thread});
  final PotThread thread;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.groupDeleteTitle(thread.name)),
        content: Text(l10n.groupDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-group'),
            style: FilledButton.styleFrom(
              backgroundColor: PircColorTokens.of(context)['status.danger'],
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    final api = ref.read(apiProvider);
    if (sure != true || api == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ThreadsApi(api).delete(thread.id);
      ref.invalidate(threadsProvider);
      if (context.mounted) context.go('/chat');
    } on PircException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final members = groupMembers(thread, pots);
    final full = watchFullPots(ref, [for (final p in members) p.id]);
    final host = members.where((p) => p.id == thread.hostPotId).firstOrNull;
    final chevron = Icon(
      LucideIcons.chevronRight,
      size: 16,
      color: colors['text.faint'],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            children: [
              GroupThreadAvatar.of(
                thread,
                members: members,
                size: AvatarSize.lg,
                ring: colors['surface.grouped'],
              ),
              const SizedBox(height: 14),
              Text(
                thread.name,
                key: const ValueKey('group-info-name'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  height: 30 / 22,
                  fontWeight: FontWeight.w600,
                  color: colors['text.primary'],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('group-edit-look'),
                onPressed: () => _showSheet(
                  context,
                  (_) => _LookSheet(thread: thread, members: members),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: colors['surface.layer'],
                  foregroundColor: colors['text.primary'],
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: const StadiumBorder(),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                child: Text(l10n.groupEditLook),
              ),
            ],
          ),
        ),
        GroupLabel(l10n.groupMembersCount(members.length + 1)),
        GroupedList(
          key: const ValueKey('group-info-members'),
          children: [
            GroupedRow(
              leading: Avatar(
                name: l10n.handoverMeAvatar,
                me: true,
                size: AvatarSize.md,
              ),
              title: l10n.chatAuthorYou,
              subtitle: l10n.groupYouDetail,
              wrapSubtitle: true,
            ),
            for (final pot in members)
              GroupedRow(
                key: ValueKey('group-member-${pot.id}'),
                leading: PotAvatar(pot: pot, size: AvatarSize.md),
                titleWidget: Row(
                  spacing: 6,
                  children: [
                    Flexible(
                      child: Text(
                        pot.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (pot.id == thread.hostPotId) HostTag(l10n.groupHostTag),
                  ],
                ),
                subtitle: [
                  if (pot.intro.isNotEmpty) pot.intro,
                  potReachBudgetLine(l10n, pot, full[pot.id]),
                ].where((s) => s.isNotEmpty).join(' · '),
                wrapSubtitle: true,
                trailing: chevron,
                onTap: () => context.go(potProfileLocation(pot.id)),
              ),
            GroupedRow(
              key: const ValueKey('group-edit-members'),
              onTap: () =>
                  _showSheet(context, (_) => _MembersSheet(thread: thread)),
              titleWidget: Row(
                spacing: 6,
                children: [
                  Icon(
                    LucideIcons.plus,
                    size: 18,
                    color: colors['accent.pressed'],
                  ),
                  Flexible(
                    child: Text(
                      l10n.groupEditMembers,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors['accent.pressed'],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        GroupNote(l10n.groupPermissionsNote),
        GroupLabel(l10n.settings),
        GroupedList(
          children: [
            GroupedRow(
              key: const ValueKey('group-edit-host'),
              title: l10n.groupHost,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Text(
                    host?.name ?? l10n.groupNoHost,
                    style: TextStyle(fontSize: 15, color: colors['text.muted']),
                  ),
                  chevron,
                ],
              ),
              onTap: () => _showSheet(
                context,
                (_) => _HostSheet(thread: thread, members: members),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: FilledButton(
            key: const ValueKey('group-delete'),
            onPressed: () => _delete(context, ref),
            style: FilledButton.styleFrom(
              backgroundColor: colors['status.dangerSoft'],
              foregroundColor: colors['status.danger'],
              minimumSize: const Size.fromHeight(44),
              shape: const StadiumBorder(),
              textStyle: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontSize: 15),
            ),
            child: Text(l10n.groupDelete),
          ),
        ),
        GroupNote(
          l10n.groupDeleteNote,
          textAlign: TextAlign.center,
          padding: const EdgeInsets.symmetric(horizontal: 32),
        ),
      ],
    );
  }
}

Future<void> _showSheet(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: PircColorTokens.of(context)['surface.grouped'],
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: builder(context),
          ),
        ),
      ),
    );

/// Saving an edit of a group: the revision the edit started from, the
/// refusal or conflict to show, and the sheet around the fields.
abstract class _EditState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  PotThread get start;

  /// The revision the next save sends: the group's when the edit started,
  /// or after a 409 the one read again.
  late int _revision = start.revision;
  bool _busy = false;
  String? _error;
  bool _conflict = false;

  /// What [save] would change; Save is enabled while it is true.
  bool get changed;

  /// The local problem that keeps Save from sending, if any.
  String? get problem => null;

  Future<PotThread> patch(ThreadsApi threads, int revision);

  Future<void> save() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final threads = ThreadsApi(api);
    try {
      await patch(threads, _revision);
      ref.invalidate(groupThreadProvider(start.id));
      ref.invalidate(threadsProvider);
      if (mounted) Navigator.pop(context);
    } on PircException catch (error) {
      if (error is ApiError && error.status == 409) {
        // Another device changed the group: keep the edit, take the new
        // revision, and say so.
        try {
          final now = await threads.read(start.id);
          _revision = now.revision;
        } on PircException {
          // The next save answers 409 again and reads once more.
        }
        ref.invalidate(groupThreadProvider(start.id));
        ref.invalidate(threadsProvider);
        if (mounted) {
          setState(() {
            _busy = false;
            _conflict = true;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _conflict = false;
          _error = error.message;
        });
      }
    }
  }

  Widget sheet({
    required String title,
    required List<Widget> children,
    String? note,
  }) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final problem = this.problem;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_conflict)
                  Container(
                    key: const ValueKey('group-conflict'),
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: colors['status.warningSoft'],
                      borderRadius: BorderRadius.circular(PircRadius.md),
                    ),
                    child: Text(
                      l10n.groupConflict,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 20 / 13.5,
                        color: colors['text.warning'],
                      ),
                    ),
                  ),
                if (_error != null)
                  ErrorBox(_error!, key: const ValueKey('group-edit-error')),
                ...children,
                if (problem != null)
                  GroupNote(
                    problem,
                    error: true,
                    key: const ValueKey('group-edit-problem'),
                  ),
                if (note != null) GroupNote(note),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: FilledButton(
            key: const ValueKey('group-edit-save'),
            style: inkButtonStyle(context),
            onPressed: _busy || !changed || problem != null ? null : save,
            child: Text(l10n.save),
          ),
        ),
      ],
    );
  }
}

/// "Change name and avatar": the name and the avatar (faces, a colour or
/// a picture).
class _LookSheet extends ConsumerStatefulWidget {
  const _LookSheet({required this.thread, required this.members});
  final PotThread thread;
  final List<PotSummary> members;

  @override
  ConsumerState<_LookSheet> createState() => _LookSheetState();
}

class _LookSheetState extends _EditState<_LookSheet> {
  @override
  PotThread get start => widget.thread;

  late final _name = TextEditingController(text: start.name);
  late int? _color = start.avatarColor;
  late String? _image = start.avatarImage;
  Uint8List? _bytes;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  bool get changed =>
      _name.text.trim() != start.name ||
      _color != start.avatarColor ||
      _image != start.avatarImage;

  @override
  String? get problem {
    final issues = groupIssues(
      name: _name.text,
      members: start.pots,
      host: start.pots.firstOrNull,
    );
    for (final issue in [GroupIssue.nameMissing, GroupIssue.nameTooLong]) {
      if (issues.contains(issue)) {
        return groupIssueText(AppLocalizations.of(context), issue);
      }
    }
    return null;
  }

  @override
  Future<PotThread> patch(ThreadsApi threads, int revision) {
    final name = _name.text.trim();
    return threads.update(
      start.id,
      revision: revision,
      name: name != start.name ? name : null,
      avatarColor: _color != start.avatarColor ? _color : null,
      removeAvatarColor: _color == null && start.avatarColor != null,
      avatarImage: _image != start.avatarImage ? _image : null,
      removeAvatarImage: _image == null && start.avatarImage != null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    return sheet(
      title: l10n.groupEditLook,
      children: [
        Center(
          child: GroupThreadAvatar(
            name: _name.text.trim(),
            members: widget.members,
            color: _color,
            image: _image,
            picture: avatarPicture(ref, _image, _bytes),
            size: AvatarSize.lg,
            ring: colors['surface.grouped'],
          ),
        ),
        AvatarPicker(
          color: _color,
          image: _image,
          bytes: _bytes,
          note: l10n.groupAvatarNote,
          leading: [
            FacesSwatch(
              selected: _color == null,
              onTap: () => setState(() => _color = null),
            ),
          ],
          onColor: (color) => setState(() => _color = color),
          onPicture: (id, bytes) => setState(() {
            _image = id;
            _bytes = bytes;
          }),
        ),
        GroupLabel(l10n.groupName),
        GroupedList(
          children: [
            FormInputRow(
              field: TextField(
                key: const ValueKey('group-edit-name'),
                controller: _name,
                onChanged: (_) => setState(() {}),
                style: formFieldStyle(context, size: 15.5),
                decoration: plainField(context, l10n.groupNameHint),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "Add or remove members": every pot that is not archived (and any
/// member that is), ticked when a member; the host stays.
class _MembersSheet extends ConsumerStatefulWidget {
  const _MembersSheet({required this.thread});
  final PotThread thread;

  @override
  ConsumerState<_MembersSheet> createState() => _MembersSheetState();
}

class _MembersSheetState extends _EditState<_MembersSheet> {
  @override
  PotThread get start => widget.thread;

  late final Set<String> _members = {...start.pots};

  List<String> get _ordered => inPotOrder(_members, readPots(ref));

  @override
  bool get changed =>
      _members.length != start.pots.length || !_members.containsAll(start.pots);

  @override
  String? get problem =>
      _members.length < groupMinMembers || _members.length > groupMaxMembers
      ? AppLocalizations.of(context).groupMemberRule
      : null;

  @override
  Future<PotThread> patch(ThreadsApi threads, int revision) =>
      threads.update(start.id, revision: revision, memberPotIds: _ordered);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pots = [
      for (final pot in ref.watch(potsProvider).value ?? const <PotSummary>[])
        if (pot.state != 'archived' || start.pots.contains(pot.id)) pot,
    ];
    final full = watchFullPots(ref, [for (final p in pots) p.id]);
    final atMost = _members.length >= groupMaxMembers;
    return sheet(
      title: l10n.groupMembers,
      children: [
        const SizedBox(height: 8),
        GroupedList(
          key: const ValueKey('group-members-sheet'),
          children: [
            for (final pot in pots)
              MemberCheckRow(
                key: ValueKey('member-${pot.id}'),
                pot: pot,
                subtitle: pot.id == start.hostPotId
                    ? l10n.groupHostStays
                    : potMemberLine(l10n, pot, full[pot.id]),
                value: _members.contains(pot.id),
                onChanged:
                    pot.id == start.hostPotId ||
                        (atMost && !_members.contains(pot.id))
                    ? null
                    : () => setState(() {
                        if (!_members.remove(pot.id)) _members.add(pot.id);
                      }),
              ),
          ],
        ),
      ],
    );
  }
}

/// The host: one of the members.
class _HostSheet extends ConsumerStatefulWidget {
  const _HostSheet({required this.thread, required this.members});
  final PotThread thread;
  final List<PotSummary> members;

  @override
  ConsumerState<_HostSheet> createState() => _HostSheetState();
}

class _HostSheetState extends _EditState<_HostSheet> {
  @override
  PotThread get start => widget.thread;

  late String? _host = start.hostPotId;

  @override
  bool get changed => _host != null && _host != start.hostPotId;

  @override
  Future<PotThread> patch(ThreadsApi threads, int revision) =>
      threads.update(start.id, revision: revision, hostPotId: _host);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final full = watchFullPots(ref, [for (final p in widget.members) p.id]);
    return sheet(
      title: l10n.groupHost,
      note: l10n.groupHostNote,
      children: [
        const SizedBox(height: 8),
        GroupedList(
          key: const ValueKey('group-host-sheet'),
          children: [
            for (final pot in widget.members)
              RadioRow(
                key: ValueKey('host-${pot.id}'),
                title: pot.name,
                subtitle: potMemberLine(l10n, pot, full[pot.id]),
                selected: _host == pot.id,
                onTap: () => setState(() => _host = pot.id),
              ),
          ],
        ),
      ],
    );
  }
}
