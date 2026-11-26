import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../work/work_data.dart';
import 'chat_data.dart';
import 'chat_list_screen.dart';
import 'group_data.dart';
import 'handover_parts.dart';
import 'new_pot_screen.dart';
import 'pot_form.dart';

/// New group (E32): the avatar (the members' faces, a colour or a
/// picture), the name, the members (2–16 of the pots that are not
/// archived) and the host among them. Create posts it once and opens the
/// group's conversation; a refusal shows the Gateway's message as it is.
class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key, this.showBack = true});

  /// Shows Cancel (the content pane hides it on desktop, where the list
  /// stays beside it).
  final bool showBack;

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _name = TextEditingController();
  final _members = <String>{};
  String? _host;
  int? _color;
  String? _image;
  Uint8List? _bytes;

  /// Create was pressed: the problems are shown.
  bool _checked = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toggle(String id) => setState(() {
    if (!_members.remove(id)) _members.add(id);
    if (!_members.contains(_host)) _host = null;
  });

  Future<void> _create(List<String> members) async {
    final issues = groupIssues(name: _name.text, members: members, host: _host);
    if (issues.isNotEmpty) {
      setState(() => _checked = true);
      return;
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final thread = await ThreadsApi(api).createGroup(
        name: _name.text.trim(),
        hostPotId: _host!,
        memberPotIds: members,
        avatarColor: _color,
        avatarImage: _image,
      );
      if (!mounted) return;
      ref.invalidate(threadsProvider);
      context.go(chatLocation(thread.id));
    } on PircException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final pots = [
      for (final pot in ref.watch(potsProvider).value ?? const <PotSummary>[])
        if (pot.state != 'archived') pot,
    ];
    final full = watchFullPots(ref, [for (final pot in pots) pot.id]);
    final members = inPotOrder(_members, pots);
    final chosen = [
      for (final pot in pots)
        if (_members.contains(pot.id)) pot,
    ];
    final issues = _checked
        ? groupIssues(name: _name.text, members: members, host: _host)
        : const <GroupIssue>{};
    final full16 = members.length >= groupMaxMembers;
    List<Widget> notes(List<GroupIssue> these) => [
      for (final issue in these)
        if (issues.contains(issue))
          GroupNote(
            groupIssueText(l10n, issue),
            error: true,
            key: ValueKey('group-issue-${issue.name}'),
          ),
    ];
    Widget narrow(Widget child) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
    final picture = avatarPicture(ref, _image, _bytes);
    return Scaffold(
      backgroundColor: colors['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              title: l10n.chatNewGroup,
              subtitle: l10n.groupNewCount(members.length),
              leading: widget.showBack
                  ? TextButton(
                      key: const ValueKey('group-cancel'),
                      onPressed: () => context.go('/chat'),
                      style: TextButton.styleFrom(
                        foregroundColor: colors['text.primary'],
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: const StadiumBorder(),
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(fontSize: 14),
                      ),
                      child: Text(l10n.cancel),
                    )
                  : null,
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('group-scroll'),
                padding: const EdgeInsets.only(bottom: 16),
                child: narrow(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null)
                        ErrorBox(_error!, key: const ValueKey('group-error')),
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 8),
                        child: Center(
                          child: GroupThreadAvatar(
                            key: const ValueKey('group-avatar'),
                            name: _name.text.trim(),
                            members: chosen,
                            color: _color,
                            image: _image,
                            picture: picture,
                            size: AvatarSize.lg,
                            ring: colors['surface.grouped'],
                          ),
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
                              key: const ValueKey('group-name'),
                              controller: _name,
                              onChanged: (_) => setState(() {}),
                              style: formFieldStyle(context, size: 15.5),
                              decoration: plainField(
                                context,
                                l10n.groupNameHint,
                              ),
                            ),
                          ),
                        ],
                      ),
                      ...notes(const [
                        GroupIssue.nameMissing,
                        GroupIssue.nameTooLong,
                      ]),
                      GroupLabel(l10n.groupMembers),
                      GroupedList(
                        key: const ValueKey('group-members'),
                        children: [
                          for (final pot in pots)
                            MemberCheckRow(
                              key: ValueKey('member-${pot.id}'),
                              pot: pot,
                              subtitle: potMemberLine(l10n, pot, full[pot.id]),
                              value: _members.contains(pot.id),
                              onChanged: full16 && !_members.contains(pot.id)
                                  ? null
                                  : () => _toggle(pot.id),
                            ),
                        ],
                      ),
                      ...notes(const [GroupIssue.memberCount]),
                      GroupLabel(l10n.groupHost),
                      if (chosen.isEmpty)
                        GroupNote(l10n.groupHostPickFirst)
                      else
                        GroupedList(
                          key: const ValueKey('group-hosts'),
                          children: [
                            for (final pot in chosen)
                              RadioRow(
                                key: ValueKey('host-${pot.id}'),
                                title: pot.name,
                                subtitle: potMemberLine(
                                  l10n,
                                  pot,
                                  full[pot.id],
                                ),
                                selected: _host == pot.id,
                                onTap: () => setState(() => _host = pot.id),
                              ),
                          ],
                        ),
                      ...notes(const [GroupIssue.hostMissing]),
                      GroupNote(l10n.groupHostNote),
                    ],
                  ),
                ),
              ),
            ),
            narrow(
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: FilledButton(
                  key: const ValueKey('group-create'),
                  style: inkButtonStyle(context),
                  onPressed: _busy ? null : () => _create(members),
                  child: _busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors['action.onPrimary'],
                          ),
                        )
                      : Text(l10n.groupCreate),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "members' faces" swatch: a group without a colour shows two of its
/// members (`e-sw` with a 22 `e-avg` of two blank faces).
class FacesSwatch extends StatelessWidget {
  const FacesSwatch({super.key, required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    Widget face(int color) => Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        color: colors[avatarColorToken(color)],
        shape: BoxShape.circle,
      ),
    );
    return AvatarSwatch(
      key: const ValueKey('swatch-faces'),
      color: colors['surface.layer'],
      selected: selected,
      label: AppLocalizations.of(context).groupAvatarFaces,
      onTap: onTap,
      child: SizedBox.square(
        dimension: 22,
        child: Stack(
          children: [
            Positioned(left: 0, top: 0, child: face(1)),
            Positioned(right: 0, bottom: 0, child: face(3)),
          ],
        ),
      ),
    );
  }
}

/// `c-grow` with a member's avatar (36), its name and line, and a round
/// tick (`e-check`, 22). A null [onChanged] disables it (16 members).
class MemberCheckRow extends StatelessWidget {
  const MemberCheckRow({
    super.key,
    required this.pot,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final PotSummary pot;
  final String subtitle;
  final bool value;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: value,
    child: GroupedRow(
      leading: PotAvatar(pot: pot, size: AvatarSize.md),
      title: pot.name,
      subtitle: subtitle,
      enabled: onChanged != null,
      onTap: onChanged,
      trailing: IgnorePointer(
        child: RoundCheck(
          value: value,
          onChanged: (_) {},
          size: 22,
          hitSize: 22,
        ),
      ),
    ),
  );
}
